# PortalCaptureKit

Screen capture through `org.freedesktop.portal.ScreenCast` and PipeWire — the
Wayland-capable capture path for the Linux sharer.

Wrapped the way `X11CaptureKit` wraps libxcb:

| Target             | What it is                                                            |
|--------------------|-----------------------------------------------------------------------|
| `CDBusSys`         | `systemLibrary` over libdbus                                          |
| `CPipeWireSys`     | `systemLibrary` over libpipewire + libspa                             |
| `CPortalCapture`   | C shim — the portal handshake and the PipeWire stream                 |
| `CPortalFakeBus`   | a fake portal service, for tests. **Not in the library product.**     |
| `PortalCaptureKit` | Foundation-only Swift wrapper (`PortalSession`, `PortalStream`)       |
| `portal-probe`     | the link check and the two drivable checks (below)                    |

## Status — read this before trusting anything below

This is a **first increment**. It is not wired into `Apps/linux`, there is no
`CaptureEncoding` conformance yet, and **not one pixel has been captured
through it.** What has and has not actually been run is in
[What is proven](#what-is-proven-and-what-is-not), and the boundary is sharper
than usual because this package's central feature cannot be exercised without a
human at a desk.

## Why the portal, when X11 capture already works

`X11CaptureKit` grabs an X display's root window. On a Wayland session there is
no such thing: XWayland exposes a root window containing only XWayland clients,
so a "share my screen" on GNOME or KDE today shows viewers an empty desktop with
a few legacy apps on it. It also cannot capture one window or one application at
all — that needs the compositor's cooperation, which on Linux means the portal.

So this unblocks three rows of `docs/platform-support.md` at once (share a
window, share an app, Wayland capture), which is why `plans/platform-alignment.md`
calls 3.3 the highest-leverage Linux item.

X11 capture is not superseded. It runs headlessly under Xvfb, which is what
makes `linux-x11-capture` a real CI gate; nothing here ever will be. Both sit
behind the same `CaptureEncoding` seam
(`Packages/TailscreenKit/Sources/TailscreenSharer/SharerBackends.swift`), whose
doc comment already names "PipeWire via the ScreenCast portal" as an expected
backend.

## The consent model, which is the point and not an obstacle

Every share starts with a dialog the **compositor** draws — not us — and a
person clicks. There is no headless path, no flag, and nothing in this package
that tries to find one. That is the design working.

Two things follow that are easy to get wrong:

- **A declined request is not an error.** `PortalSession.Failure.cancelled` is
  its own case for exactly this reason. A sharer UI that shows a failure dialog
  because somebody chose not to share their screen is worse than one that shows
  nothing. `portal-probe --handshake-cancel` is a gate on precisely that.
- **`restore_token` is not a way to skip the dialog.** It is the *portal's* own
  consent memory, issued because the user ticked its box, and the portal decides
  whether to honour it — it may prompt anyway. We pass it through and store what
  comes back; we never assume it works.

Also: `ts_portal_close_session` is called on teardown and on `deinit`. Leaving
a session open leaves the desktop's "your screen is being shared" indicator on
the user's panel after the share ended, which reads as spyware.

## Colour: nothing happens here

**This package performs no colour conversion.** It hands back packed BGRA/BGRx
and a stride, and the repo's portable `BGRAToI420` (in `TailscreenProtocol`)
converts — exactly the split `WGCCaptureKit` → `TailscreenSharerWGC` already
uses on Windows, where the capture package is likewise pixel-format-only and the
`CaptureEncoding` conformance owns the conversion.

That is the "reuse rather than write a second path" answer, and it is a reuse by
*subtraction*: there are already two implementations of this arithmetic in the
repo (`BGRAToI420` in Swift, `x11cap_bgra_to_i420` in C) plus the viewer's YUV
shader inverting it, and all three have to agree or every frame is washed out or
crushed with no error anywhere. A third would be a third thing to keep in step.

Depending on `X11CaptureKit` to reuse its C version was the other option and was
rejected: it would make the *Wayland* capture package pull in libxcb, which is
the dependency the portal exists to shed.

What this package does instead is make sure the buffer it hands over is the one
`BGRAToI420` expects — see the format trap below.

## Traps

Four, and none of them fails loudly.

**1 · Subscribe to the Response signal before making the call.** Every portal
method returns immediately with an object path; the real answer arrives later as
`org.freedesktop.portal.Request::Response` on that path. The client is expected
to *derive the path itself* from its own unique bus name plus a token it chose,
and to have the match rule in place before the call — a portal that answers fast
emits the signal first otherwise, and the client waits forever. Every call times
out, with no error from anything.

This is not theoretical here: breaking the derivation and re-running
`--handshake-test` produced exactly that timeout, and the spec-mandated
"adopt the handle the portal returned" fallback **did not save it**, because
subscribing to the adopted path happens after the call and loses the same race.
The fallback is worth having for slower portals; it is not a substitute for
getting the derivation right. `PortalRequestPathTests` pins the derivation
against hand-written strings.

**2 · Ask for BGRx/BGRA only.** PipeWire will happily negotiate RGBx, YUY2 or
NV12 if you offer them, and the buffer then is not what `BGRAToI420` expects —
the result is swapped channels or garbage, not an error.

**3 · Constrain `SPA_PARAM_BUFFERS_dataType` to MemPtr/MemFd.** On a GPU
compositor the producer would rather hand over a DMA-BUF, and then
`datas[0].data` is `NULL` and the pixels live in GPU memory behind an EGL/GBM
import this package does not do. Leave `dataType` unconstrained and you get a
stream that connects, runs, and delivers nothing but null pointers. Accepting
the CPU-copy cost is a deliberate first-increment choice; zero-copy DMA-BUF
import belongs with a GPU encoder, not here.

**4 · `stride` is not `width * 4`.** PipeWire producers pad rows. Reading at
`width * 4` skews the image progressively further with every row — a recognisable
diagonal smear rather than a crash.

Two smaller ones. `pw_context_connect_fd` **takes** the descriptor and closes it
when the core goes away, so closing it yourself as well is a double close on a
number the process may have reused — `ts_pwcap_open` therefore owns the fd
unconditionally, including on its own failure paths. And the session handle
comes back from `CreateSession` as a plain **string** but must be sent to every
later method as an **object path**; that asymmetry is in the spec.

## What is proven, and what is not

This section exists because this repo has shipped gates that could not fail.

Actually run, on a container with libdbus and libpipewire and **no desktop
session of any kind**:

| Check | What it proves |
|---|---|
| `swift build` | the shim compiles against both system libraries |
| `swift test` (13 tests) | the Request-path derivation against hand-written strings, the portal's source-type / cursor-mode / persist-mode wire constants, and the failure-code mapping — in particular that a decline is its own case |
| `portal-probe --link-check` | **both libraries actually link**, and a call into each returns. A SwiftPM library target is compiled but never linked, so a missing `-lpipewire-0.3` would otherwise stay invisible until something downstream linked it |
| `portal-probe --handshake-test` | the whole client handshake against `CPortalFakeBus` on a private bus: CreateSession → SelectSources → Start → OpenPipeWireRemote, the options dicts a server can read, the subscribe-before-call ordering, the `streams` array parsed, the restore token picked up, and a file descriptor surviving the round trip usable (`fstat`) |
| `portal-probe --handshake-cancel` | a declined request surfaces as `.cancelled`, not as an error |

The handshake checks were **verified falsifiable**: with the Request-path
derivation deliberately broken, `--handshake-test` fails with a timeout naming
the path, and restoring it makes it pass again.

Not proven by anything here, and not provable without a desktop session:

- **Any real portal.** The fake answers instantly and correctly. It is not
  xdg-desktop-portal-gnome, -kde, -wlr or -gtk, each of which has its own
  quirks, and it has no consent dialog.
- **The entire PipeWire half.** `portal_stream.c` compiles and links. No stream
  has been opened, no format negotiated, no buffer dequeued, no frame delivered.
  Every one of the four traps above is reasoned from the API contract, not
  observed. **Assume this half has bugs.**
- **A single pixel.** Nothing in this repo has yet turned a portal frame into
  video.
- Cursor compositing, multi-monitor selection, mid-stream resize, DMA-BUF
  rejection actually happening, and the restore-token flow across restarts.

The CI leg (`linux-portal`) runs exactly the five rows in the table above and
claims exactly that. It is a **compile, link and D-Bus-protocol** gate. It is
not a capture gate and must never be described as one.

## Build & test

```bash
# Debian/Ubuntu
sudo apt-get install -y pkg-config libdbus-1-dev libpipewire-0.3-dev dbus

swift build --package-path Packages/PortalCaptureKit
swift test  --package-path Packages/PortalCaptureKit

P=Packages/PortalCaptureKit/.build/debug/portal-probe
$P --link-check
dbus-run-session -- $P --handshake-test
dbus-run-session -- $P --handshake-cancel

# On a real desktop session, with a person present:
$P --capabilities     # asks the real portal what it offers; raises no dialog
$P --capture          # raises the consent dialog, opens a stream, counts frames
```

`--handshake-test` and `--handshake-cancel` **skip** (exit 0) with no
`DBUS_SESSION_BUS_ADDRESS`, which is why the CI leg wraps them in
`dbus-run-session` — without it they would pass by not running.

On a machine with a real desktop the fake portal cannot start at all: it asks
for `org.freedesktop.portal.Desktop` with `DO_NOT_QUEUE` and never replaces an
existing owner, so it fails rather than displacing the actual consent authority.
Run those two under `dbus-run-session`, which is a private bus, always.

`swift build` prints `warning: prohibited flag(s): -D_REENTRANT` — that is
SwiftPM filtering a define out of libpipewire's pkg-config cflags. The include
paths it needs do come through; the define is a no-op on modern glibc.

## Next increment

In order, because each is a prerequisite for judging the next:

1. **Verify the PipeWire half against something real.** A local `pipewire`
   daemon plus a synthetic producer node would gate format negotiation, the
   buffer params, the process callback and the stride handling — the four traps
   above — without a compositor or a consent dialog. That is the largest
   unverified surface here and the cheapest remaining thing to make honest.
2. `PortalCaptureEncoder` in `TailscreenLinuxBackends`: the `CaptureEncoding`
   conformance, wiring these frames through `BGRAToI420` into the libavcodec
   encoder `X11CaptureEncoder` already uses.
3. Backend selection in `Apps/linux` — portal when there is a session bus with a
   portal on it, X11 otherwise. Note that this is *not* "Wayland → portal": the
   portal is the better path on X11 sessions too, because it is the only one that
   can share a single window.
4. Map `PickerSelection` onto the portal's picker. The macOS model (the user
   picks, then we resolve IDs) matches the portal's shape closely; the mismatch
   is that the portal returns its own opaque node, so a Linux `PickerSelection`
   is more like "what the portal gave us" than "which display id".
