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
| Off-thread audio — `ThreadedAudioSink` | was Linux-only | ✅ moved to the portable tier, reused unchanged |
| Audio out — `ALSAAudioSink` | Linux-only | ✅ **new:** `WASAPIKit` + `WASAPIAudioSink` |
| Video surface — `GtkVideoView` + `CGtkVideo` | Linux-only | ✅ **new:** `WinUIVideoView` (`Image` + `WriteableBitmap`; `SwapChainPanel` later) |
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

`spikes/windows-tsnet-bridge/` retired this risk before any UI work, with no
tsnet involved so a failure pointed at the primitive rather than at forty layers
of Tailscale. It built loopback replacements for both socketpair flavours and
proved, on a real Windows runner:

- stream round trip in both directions;
- **datagram boundaries preserved** — one datagram in, exactly one out, which is
  what patch 013 depends on and what a stream socket would silently break;
- the native handle fits in a C `int` (a `SOCKET` is `UINT_PTR`, 64-bit on
  win/amd64, while `tailscale_conn` is `int`);
- the accept handoff works **without SCM_RIGHTS** — Go and native code share one
  process and therefore one handle table, so the handle *value* suffices. The
  Unix machinery exists for a constraint we do not have;
- a Go-side close surfaces to the native end as EOF.

Leg B repeated the stream and datagram checks from real C `recv()` across a cgo
c-archive boundary, because that is where linkage and runtime-init surprises
live.

**The spike and its `windows-spike` workflow have since been deleted.** They
answered their question and patch 024 shipped the answer; the `Windows build`
job now builds the real c-archive, links it into the app and runs `tsnet-probe`
against it, which is strictly stronger evidence than the spike could give. The
findings above are the record — the code was scaffolding, not the record.

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

- **W0 — bridge spike.** ✅ Green on a Windows runner, then deleted once patch
  024 shipped the real bridge. *The one that could have invalidated the shape;
  it came first.*
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
- **W4 — video.** ✅ `FFmpegVideoDecoder` behind the portable `VideoDecoding`
  seam, blitted into a WinUI `Image`/`WriteableBitmap`. The decoder moved to
  `Packages/TailscreenVideoFFmpeg` so consuming it doesn't also drag in ALSA and
  X11; the colour conversion is `I420Converter` in the portable tier, tested on
  Linux. *No frame has been watched — CI has no sharer and no display.*
- **W5 — audio.** ✅ WASAPI shared-mode rendering behind the portable
  `AudioSink` seam (`Packages/WASAPIKit`), the counterpart to ALSAKit on Linux,
  fronted by `ThreadedAudioSink` so the blocking device write stays off the
  WinUI main thread. `ThreadedAudioSink` moved from `Apps/linux` into the
  portable tier — it was always thread + queue over `AudioSink` — and the
  48 kHz mono → device-format adaptation is `MonoPCMConverter`, also portable
  and tested. *No sound has been heard.*
- **W6 — sharer.** ✅ **Windows.Graphics.Capture, not DXGI Desktop
  Duplication** — this entry used to say DXGI, and that was the wrong call.
  Duplication only ever yields a whole output; WGC has a picker and a per-window
  model, which is what actually matches macOS's `SCContentSharingPicker`, and
  sharing one window is the common case. `TailscreenSharerWGC` behind
  `CaptureEncoding`, `SendInputKit` behind `InputInjecting`, `WinOverlayKit` for
  annotations. *No real screen has been captured — CI has no display.*
- **W7 — the silently-broken parts.** ✅ Per-monitor-v2 DPI awareness (without
  it both remote control and annotations resolve to nothing, with no error);
  the overlay's owned message-pump thread; annotations advertised as a
  capability rather than assumed; the hub chrome extracted to
  `Packages/TailscreenHubUI` and shared with the GTK app; the Windows app
  typechecked on Linux CI.
- **W8 — packaging.** ← next. Installer, signing, distribution channels. See
  below; nothing here is decided yet.

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

### W8 in detail — packaging

Today the artifact is a staged directory: the exe, an explicit list of Swift
runtime DLLs, the FFmpeg LGPL DLLs, libopus, and the Windows App SDK
bootstrapper at the one literal relative path `swift-winui` looks for. That is
fine for CI and not something to hand a user.

Four decisions, and they are close to independent — the ordering below is by
what unblocks what, not by importance.

**1. Stop needing the bootstrapper.** WinUI 3 resolves its framework dependency
one of two ways: through the package graph (MSIX), or through the bootstrapper
API (unpackaged), which needs the Windows App SDK runtime installed or carried
alongside. The staging bugs this cost us — the bootstrapper at the wrong path,
then an arm64 bootstrapper beside an x64 exe — were both this mechanism. Windows
App SDK **self-contained mode** bundles the runtime and deletes the lookup
entirely. It is the smallest change here, it is independent of every other
decision, and it removes a whole bug class rather than adding an assertion
against it. Do this first regardless of what else is chosen.

**2. Signing, which is the long pole.** Since June 2023 OV/EV code signing
private keys must live on FIPS 140-2 hardware, so **a `.pfx` in CI secrets is no
longer possible for a newly issued certificate** — the pattern the macOS release
workflow uses does not transfer. The options are a cloud signing service (Azure
Trusted Signing, DigiCert KeyLocker, SSL.com eSigner), a hardware token on a
self-hosted runner, or **SignPath**, which has a free tier for OSS projects and
a GitHub Actions integration. SignPath is the obvious first call for an MIT
project; Certum's OSS-priced hardware certs are the usual alternative.

*Check Azure Trusted Signing's eligibility rules before planning around it —
Microsoft has changed who can onboard more than once, and this note may be out
of date by the time you read it.*

Unsigned is not a neutral choice: SmartScreen warns on download and first run,
which lands badly for an app that then asks for screen capture and input
injection. This has the longest lead time of anything in W8, so start it early
even if the installer format is undecided.

**3. Installer format.**

- **MSIX** — Microsoft's modern format and WinUI 3's native story. Clean
  install/uninstall, differential updates, Store-eligible, and it makes decision
  1 moot by resolving the framework dependency through the package graph. Costs:
  the manifest `Publisher` must match the signing cert's subject exactly, a
  self-signed cert means users hand-installing it, and the container's
  virtualized filesystem/registry occasionally surprises apps that write beside
  their exe (we don't — tsnet state is in AppData).
- **Inno Setup** — what most OSS desktop projects actually ship. One
  self-contained exe, handles shortcuts/uninstall/upgrade-in-place without
  ceremony. Unglamorous, hard to beat at our size.
- **WiX / MSI** — the enterprise answer: Group Policy deployment, admin
  transforms, per-machine installs. WiX v4 is a ground-up rewrite from v3, so
  v3-era material misleads. Heaviest to author; worth it only if someone asks
  for managed deployment.
- **Velopack** — successor to Squirrel.Windows. Its distinguishing feature is
  auto-update with delta packages. Premature until there is a release cadence to
  update along.

**4. Distribution channels, which are layered on top and not alternatives to
the above.** All three want the same thing: a stable download URL and a
checksum. None of them changes the format decision, which is why they come last
and are individually cheap.

- **winget** — ships with Windows 11 (via App Installer), which is the whole
  argument. Declarative YAML manifest submitted to `microsoft/winget-pkgs`
  pointing at an installer plus hashes; accepts MSI, MSIX or plain exe. Highest
  leverage per unit of effort for a developer-facing tool.
- **Scoop** — developer-focused, installs per-user with no admin rights, JSON
  manifests in git "buckets". The cheapest to publish, because **you can host
  your own bucket** — a repo with a manifest in it — with no review queue at
  all. Good fit for the audience most likely to install a Tailscale-adjacent
  tool early.
- **Chocolatey** — predates winget (2011) and still has the deepest catalogue
  and the strongest sysadmin/ops following. Packages are NuGet `.nupkg`
  containers wrapping **PowerShell install scripts**, which is the real
  difference from winget's declarative manifests: a Chocolatey package can do
  arbitrary work — dependency chains, custom logic, papering over a badly
  behaved installer — where a winget manifest essentially points at one. That
  power is also its cost: it's a script to maintain per release, the community
  repository has a moderation queue that adds latency to a release, and the
  `AU` PowerShell module exists specifically because keeping package versions
  current by hand doesn't scale. At 142 MB the package should download from
  GitHub Releases with a checksum rather than embed the binary — which is what
  Chocolatey's own guidelines want anyway.

  **Verdict for us: winget first, Scoop second, Chocolatey if asked for.** Its
  audience skews toward automated fleet provisioning, which is not where a
  peer-to-peer screen-sharing GUI finds its first users. Revisit if anyone asks
  to deploy Tailscreen across an estate.

**LGPL constraint on all of the above.** The FFmpeg DLLs are LGPL shared builds,
deliberately — the GPL builds carry libx264 and would infect this MIT codebase.
Whatever the installer does, they must stay separately replaceable DLLs and the
package must carry the LGPL text and the relink offer. Any format here handles
that; the thing to avoid is a single-file bundler helpfully merging them in.

#### W8a — what the arm64 probe has actually established

Run natively on a `windows-11-arm` runner (GA for public repos, 4 vCPU, free),
so none of this is cross-compilation.

**Confirmed:**

- **Swift has a real Windows arm64 toolchain** and `SwiftyLab/setup-swift`
  resolves it: `swift-6.1.3-RELEASE-windows10-arm64`. Published since 6.0.
- **Go builds the patched libtailscale c-archive for `windows/arm64`** —
  55,378,236 bytes, with the full patch series including `bridge_windows.go`
  applied. The bridge needed no arm64-specific work: loopback TCP/UDP pairs and
  a handle value carry over unchanged.
- **FFmpeg has a supply route.** BtbN publishes
  `ffmpeg-n7.1-latest-winarm64-lgpl-shared-7.1.zip`, identical naming to the
  `win64` asset already consumed, so the video path needs a URL change and not a
  from-source build.
- **`CGoRuntimeInit` already handles arm64** — `#elif defined(_M_ARM64)` →
  `_rt0_arm64_windows_lib`, with a hard `#error` for an unrecognised
  architecture. Patch 026 anticipated this.

**The one real blocker found, and it is not ours:** cgo picks its C compiler
implicitly — `gcc` on PATH unless `CC` says otherwise — and the arm64 runner
image carries an **x86_64** gcc. It duly used it, and the build died inside
`runtime/cgo`:

```
gcc_arm64.S:30: Error: no such instruction: `stp x29,x30,[sp,'
```

`stp` is an ARM64 instruction, so that message is an x86 assembler reading ARM64
assembly. Nothing in it names a compiler, which is the whole argument for
answering this in a three-minute probe rather than inside a forty-minute app
build. The job now inventories every C compiler it can find, prints each one's
`-dumpmachine`, and chooses on that evidence. On this image **clang natively
targets arm64**, so no `--target` is needed and `CGO_TARGET_FLAGS` comes back
empty — the explicit-target path is retained as a fallback for images where it
would not.

Swift setup therefore runs **before** Go in that job, opposite to the app job,
because the Swift toolchain is where that clang comes from.

**Still open:** whether `tsnet-probe` links and `tailscale_new()` returns on
arm64, and then the app itself — WinUI, FFmpeg, staging. The probe reached the
staging step and tripped a bug in this job's own copy of it (`cp` onto the
dangling `lib/libtailscale.a` symlink, which the app job has always deleted
first), so the link and run legs are still unproven rather than failed.

**Also unresolved, and cheap to forget:** no native arm64 build, so today's x64
artifact runs under emulation on ARM devices (which is how the W2/W3 manual
verification was done). Whether W8 ships a second architecture or an arm64
build lands separately is an open question, but the installer and the winget
manifest both grow a dimension when it does.

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
