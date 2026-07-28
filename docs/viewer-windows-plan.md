---
title: Windows app on swift-cross-ui / WinUI
nav_order: 13
permalink: /viewer-windows-plan/
---

# Bringing Tailscreen to Windows (swift-cross-ui / WinUI)

This is **L5** of the [Linux GTK viewer plan](/linux-viewer-gtk-plan/): the same
native-feeling desktop app on **Windows**, reusing everything the Linux effort
proved. It is a porting plan, not an implementation — except for one spike
(below), which exists because the plan's original toolchain claim turned out to
be wrong.

> **Correction.** An earlier version of this document said the native-dependency
> work was "build `libtailscale.a` for Windows — add a `windows/amd64` target".
> That is not true, and it understated the single largest item by a wide margin.
> The measurement is in [the blocker](#the-real-blocker-libtailscales-gonative-bridge).

## Two distances, not one

The port splits into two very different jobs, and conflating them is what made
the original estimate wrong:

- **A Windows viewer** is close. There is even a route that sidesteps the
  blocker entirely (see [the escape route](#the-escape-route-and-its-ceiling)).
- **A Windows sharer** is not, because it needs inbound tailnet listeners —
  exactly what the broken bridge provides.

## Why most of it is already done

The hard, novel work was Linux (L0–L4, plus the sharer extraction), and almost
all of it is backend-agnostic Swift that already compiles for Windows unchanged:

| Layer | Status | Windows change |
|---|---|---|
| Receive data plane — `ViewerSession` (NACK/RR/PLI/FEC) | portable, CI-tested | none |
| Send data plane — `TailscaleScreenShareServer` (admission, fan-out, congestion, fairness) | portable | none |
| Video decode — `FFmpegVideoDecoder` | portable Swift | link Windows FFmpeg (libav*) |
| Video encode — `FFmpeg.VideoEncoder` | portable Swift | same |
| tsnet transport — `TsnetTransport` | portable Swift | **see the blocker** |
| Back-channel — `ViewerBackChannel` | portable Swift | none |
| Picker — `PickerModel` + `discoverPeers` | portable Swift | none |
| Chrome — `ViewerUIState`, `ViewerControls`, the swift-cross-ui view tree | portable Swift | none |
| Frame hand-off — `FrameStore` | portable Swift | none |
| Audio out — `ALSAAudioSink` | Linux-only | **new:** WASAPI `AudioSink` |
| Video surface — `GtkVideoView` + `CGtkVideo` | Linux-only | **new:** `SwapChainPanel` + D3D11 |
| Capture — `X11CaptureKit` + `X11CaptureEncoder` | Linux-only | **new:** DXGI Desktop Duplication behind `CaptureEncoding` |
| Input injection | none on Linux | **new:** `SendInput` + HID→VK |

The Linux platform leaves came to roughly **2,300 lines total**, which is the
right yardstick for the Windows ones:

| Leaf | Linux size |
|---|---|
| `X11CaptureKit` (capture) | 413 |
| `X11CaptureEncoder` (`CaptureEncoding` conformance) | 335 |
| `CGtkVideo` (GPU video surface) | 441 |
| `ALSAKit` (audio out) | 143 |
| `TailscreenViewerGtk` (view + glue) | 992 |

## The UI risk is smaller than it looks

The original plan named one load-bearing spike: *can a downstream `View` conform
to the public protocol, downcast the generic backend to the concrete one, and
return a native widget as `Backend.Widget` — no `@_spi`, no fork?* That is the
shape `GtkVideoView` uses today.

On Windows the trick isn't needed. swift-cross-ui's `WinUIBackend` ships
**`WinUIElementRepresentable`** — a public, documented `NSViewRepresentable`
analogue returning any `WinUI.FrameworkElement`, which `SwapChainPanel` is. The
backend is also comparably built out: 3,643 lines against `GtkBackend`'s 2,813.

So the video surface is a first-class integration, not an escape hatch. What
remains genuinely new is the D3D11 side: upload Y/U/V as three
`DXGI_FORMAT_R8_UNORM` textures, draw a fullscreen triangle with the **same
BT.709 matrix** as `cgtkvideo.c`'s fragment shader, aspect-fit with the same
`uXform` constants, `Present`. Zoom/pan and context-loss recovery map 1:1
(`cgtkvideo_reset` ↔ `DXGI_ERROR_DEVICE_REMOVED`). A C/C++ shim keeps Swift free
of COM/D3D boilerplate exactly as `CGtkVideo` keeps it free of GL.

## The real blocker: libtailscale's Go↔native bridge

Go itself is not the problem. It accepts `-buildmode=c-archive` for
`windows/amd64` and resolves the whole Windows Tailscale dependency set (wintun,
wingoes, certstore, go-winio). `tailscale.c` includes `<sys/socket.h>` and
`<unistd.h>` but never uses them — cosmetic.

`tailscale.go` is the problem. Its entire Go↔native handoff rests on:

- **`syscall.Socketpair(AF_LOCAL, …)`** — undefined for `GOOS=windows`.
- **`syscall.Sendmsg` + `syscall.UnixRights`** — SCM_RIGHTS descriptor passing,
  for which Windows has no equivalent at all.
- **`golang.org/x/sys/unix`** — Unix-only by construction.

19 call sites across 828 lines. Windows has AF_UNIX *stream* sockets since Win10
1803, but no `socketpair()` and **no AF_UNIX datagram mode** — and our own
`Patches/013-add-tsnet-listen-packet-go.patch`, the UDP path carrying all video,
uses a `SOCK_DGRAM` socketpair.

### A trap that would cost a day

Several Winsock wrappers in Go's `syscall` package **compile on Windows but are
`EWINDOWS` stubs that always fail at runtime**: `Accept`, `Recvfrom`, `Sendto`,
`SetsockoptTimeval`. `Socket`, `Bind`, `Listen`, `Connect`, `Getsockname`,
`Closesocket`, `WSARecv`, `WSASend` are real. Code written against the
compiler's opinion alone builds cleanly and fails on first use.

### The spike

`spikes/windows-tsnet-bridge/` retires this risk before any UI work, with no
tsnet involved so a failure points at the primitive rather than at forty layers
of Tailscale. It builds loopback replacements for both socketpair flavours and
proves, on a real Windows runner:

- stream round trip in both directions;
- **datagram boundaries preserved** — one datagram in, exactly one out, which is
  what patch 013 depends on and what a stream socket would silently break;
- the native handle fits in a C `int` (a `SOCKET` is `UINT_PTR`, 64-bit on
  win/amd64, while `tailscale_conn` is `int`);
- the accept handoff works **without SCM_RIGHTS** — Go and native code share one
  process and therefore one handle table, so the handle *value* suffices. The
  Unix machinery exists for a constraint we do not have;
- a Go-side close surfaces to the native end as EOF.

Leg B repeats the stream and datagram checks from real C `recv()` across a cgo
c-archive boundary, because that is where linkage and runtime-init surprises
live. CI job: `windows-spike`, on the `run-windows-spike` label or manual
dispatch — not a merge gate.

Note the replacement is *simpler* than the Unix original: the accept side uses
Go's `net` package (avoiding the `Accept` stub), which makes the Go end an
idiomatic poller-managed `net.Conn` rather than raw `syscall.Read` on a
dedicated OS thread — the Unix code carries a TODO asking for exactly that.

### Knock-on: the Swift wrapper

`TailscaleKit`'s Swift side `read`/`write`s the descriptor. On Windows those must
become `recv`/`send` — the CRT's `_read`/`_write` do not work on sockets. Patch
022 already established the pattern for platform gates.

## The escape route, and its ceiling

`tailscale_loopback()` is already in the C API, and tsnet's SOCKS5 server
supports **both `connect` and `udpAssociate`** with a real bidirectional UDP
relay. So a Windows **viewer** could use ordinary Winsock sockets to
`127.0.0.1` and never touch the bridge at all.

Two caveats, both to be measured rather than assumed:

1. Every video datagram takes an extra userspace hop through the Go relay. At
   60fps that cost is real and currently unknown.
2. SOCKS5 gives outbound dial. The **sharer** needs inbound listeners on 7447
   (TCP and UDP), and tsnet's SOCKS5 implements no `BIND`. This route reaches a
   viewer and stops.

## Toolchain, build, CI

- **Swift on Windows** (swift.org toolchain) + the **Windows App SDK** that
  `WinUIBackend` / `CWinAppSDK` target.
- **FFmpeg** libav* via vcpkg or prebuilt shared libs; **libopus** likewise.
- **libtailscale** per the blocker above — a patch series, not a build flag.
- A new SwiftPM package `Apps/windows`, sibling to `Apps/linux-gtk`, reusing
  `TailscreenViewerCore` / `TailscreenViewerTsnet` and TailscreenKit's portable
  tiers. `FrameStore` already moved into `TailscreenViewer`; `ViewerUIState`,
  `ViewerControls` and `PickerModel` should follow into a backend-neutral target
  so neither app drags in the other's UI framework.
- **CI:** a `windows-viewer` job on `windows-latest` — build, then a headless D3D
  render self-test on the **WARP** software rasterizer (`D3D_DRIVER_TYPE_WARP`),
  the moral equivalent of the Linux job's Mesa `llvmpipe`, reading back the four
  colour-bar centres and the letterbox pixel like `cgtkvideo_selftest_check`. If
  WARP read-back proves flaky headless, degrade to a compile gate plus a
  documented local render check, and say so rather than pretend around it.

## Phasing

Numbering here now matches the commits, the READMEs and the app's own doc
comments. An earlier revision of this file numbered the stages differently
(video at W2, audio at W4), which stopped being true once the bridge work split
into W1/W1b and the UI landed before the transport.

- **W0 — bridge spike.** ✅ `spikes/windows-tsnet-bridge`, green on a Windows
  runner. *The one that could have invalidated the shape; it came first.*
- **W1 — the bridge for real.** ✅ Patch 024: `bridge.go` seam,
  `bridge_windows.go` on loopback TCP/UDP pairs.
- **W1b — the Swift wrapper.** ✅ Patch 025: `recv`/`send`/`closesocket`,
  `WSAPoll`, and `WSAGetLastError` in place of `errno`.
- **W2 — the app renders.** ✅ swift-cross-ui on WinUI, portable tiers reachable
  from the UI. Confirmed by eye on a real Windows 11 desktop.
- **W3 — the app reaches the tailnet.** ✅ `lld-link` links the 56 MB Go
  c-archive; the app signs in (browser login off the IPN bus) and lists tailnet
  peers. Transport moved to `TailscreenViewerTsnet` in TailscreenKit so Windows
  consumes it without FFmpeg/ALSA/X11. *Live sign-in against a real tailnet is
  the outstanding manual check.*
- **W4 — video.** ← next. Two independent halves, below.
- **W5 — audio.** WASAPI behind the portable `AudioSink` protocol, mirroring
  what ALSAKit does on Linux.
- **W6 — sharer.** DXGI Desktop Duplication behind `CaptureEncoding`, `SendInput`
  behind `InputInjecting`. Both seams already exist and are exercised by Linux.
- **W7 — packaging.** MSIX / signed installer; a Release-workflow Windows leg.

### W4 in detail

The two halves are independent and can fail independently, so they are separate
steps rather than one "video" push.

**Decode.** Reuse `FFmpegVideoDecoder` — the same `VideoDecoding` conformance the
Linux viewer runs, already exercised against our exact RTP path by
`PipelineIntegrationTests`. Media Foundation would give hardware decode and drop
~100 MB of DLLs from the artifact, but it is a from-scratch COM backend with no
reuse, so it is an optimisation for later rather than the way in.

Two things must happen first:

1. *Gate it.* `windows-build.yml`'s `ffmpeg` job fetches a pinned LGPL shared
   FFmpeg 7.1 and runs FFmpegKit's suite on Windows. If libavcodec cannot link
   here, the decision above is void and W4 becomes Media Foundation.
2. *Extract it.* The decoder currently sits in `Apps/linux`'s
   `TailscreenViewerCore` beside the ALSA sink, so consuming it drags in
   ALSAKit and X11CaptureKit as package dependencies — the same coupling that
   kept the transport unusable on Windows until W3 moved it. It needs its own
   package depending only on FFmpegKit + TailscreenViewer.

**Licensing is not a footnote here.** Tailscreen is MIT. A GPL FFmpeg build
(the ones carrying libx264) would impose GPL on the whole app if shipped. The
viewer only ever decodes, so an LGPL build is both sufficient and the only
correct choice — and it is what CI now tests against.

**Render.** `WinUIElementRepresentable` is a full `NSViewRepresentable`
analogue (`associatedtype WinUIElementType: WinUI.FrameworkElement`, with
make/update/coordinator/sizeThatFits), so any `FrameworkElement` can host the
video. The hand-off from the decode side already exists and is portable:
`FrameStore` in `TailscreenViewer` is described as "the lock + value-type-COW
frame hand-off any renderer backend polls from its UI thread", which is exactly
what an `updateWinUIElement` tick wants.

Start with `Image` + `WriteableBitmap` and a CPU I420→BGRA conversion. It is
slow and it is correct, and it makes "pixels on screen" a small debuggable
increment. `SwapChainPanel` + D3D11 is the performance answer and can replace it
without touching the decoder, the session, or `FrameStore` — which is the point
of having the seam.

## Risks

- **Throughput.** The bridge adds a copy per datagram. Still unmeasured, and it
  matters more once video flows.
- **Startup flakiness.** The Windows app has both reached its event loop and
  aborted at startup from effectively identical binaries (`0xC000001D` /
  `0xC0000409`). One occurrence in three tsnet-linked CI runs so far. Cause
  unknown; if it clusters, chase it before W4 rather than during.
- **D3D device-lost.** Only once the renderer moves to `SwapChainPanel`: driver
  updates and sleep reset the GPU, so the shim must handle
  `DXGI_ERROR_DEVICE_REMOVED` by recreating device and swap chain. The CPU
  bitmap path has no such failure mode, which is a second reason to start there.
- **Headless render verification.** A CPU blit can be verified by reading back
  the bitmap, so unlike the D3D path it does not depend on WARP being
  deterministic.

## Threading (unchanged model)

Identical to the GTK app's proven model: the `@MainActor` transport Task runs
interleaved with the WinUI dispatcher loop; `present` → `FrameStore.set` stashes
the frame and requests a repaint marshalled to the UI thread. GTK is only ever
touched on its main thread and the same rule holds for WinUI. `FrameStore`'s
lock plus value-type COW copy already makes the cross-thread hand-off safe
regardless of backend.
