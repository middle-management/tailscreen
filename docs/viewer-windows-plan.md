---
title: Windows viewer on swift-cross-ui / WinUI
nav_order: 13
permalink: /viewer-windows-plan/
---

# Bringing the viewer to Windows (swift-cross-ui / WinUI)

This is **L5** of the [Linux GTK viewer plan](/linux-viewer-gtk-plan/): the same
native-feeling desktop viewer on **Windows**, reusing everything the Linux GTK
viewer proved. It is deliberately scoped as **"later, separate"** — a concrete
porting plan, not an implementation. Nothing Windows-specific can be built or
verified in the Linux CI container we develop in (swift-cross-ui's WinUIBackend
is the very target the GTK build *prunes* with `--product tailscreen-viewer-gtk`
so `CWinAppSDK/delayloadhelper.c` doesn't try to compile on Linux). So L5's
deliverable is this plan; the code lands once a Windows toolchain/runner exists.

## Why this is mostly done already

The hard, novel work was the Linux effort (L0–L4), and almost all of it is
**backend-agnostic Swift** that already compiles for Windows unchanged:

| Layer | Status | Windows change |
|---|---|---|
| Receive data plane — `ViewerSession` (NACK/RR/PLI/FEC) | portable, CI-tested | none |
| Video decode — `FFmpegVideoDecoder` | portable Swift | link Windows FFmpeg (libav*) |
| tsnet transport — `TsnetTransport` (`prepare`/`discoverPeers`/`run`) | portable Swift | link `libtailscale.a` built for Windows |
| Back-channel — `ViewerBackChannel` (TCP `ScreenShareMessage`) | portable Swift | none |
| Picker — `PickerModel` + `discoverPeers` → `DiscoveredSharer` | portable Swift | none |
| Chrome — `ViewerUIState`, `ViewerControls`, the swift-cross-ui view tree | portable Swift | none (WinUIBackend renders the same declarative views) |
| Frame hand-off — `FrameStore` (locked, COW copy, in `TailscreenViewer`) | portable Swift | none |
| Audio sink — `ALSAAudioSink` | Linux-only | **new:** a WASAPI (or XAudio2) `AudioSink` |
| Video surface — `GtkVideoView` + `CGtkVideo` (GL YUV→RGB) | Linux-only | **new:** a WinUI video view + D3D YUV→RGB |

Only the **two host-specific leaves** are new: the video surface and the audio
sink. Everything above the `VideoSink`/`AudioSink`/`VideoDecoding` seams is
shared verbatim — the same seams the GTK app and the mac client already plug
into.

## The one load-bearing spike (mirrors the GTK spike)

The GTK effort retired its single big risk with a spike: *can a downstream
`View` host a fast GPU video surface inside stock swift-cross-ui, no fork?* The
Windows port has the identical question against a different backend:

> Can a **downstream `struct WinUIVideoView: View`** conform to the public `View`
> protocol, downcast the generic backend to the concrete **`WinUIBackend`**,
> construct a native **`SwapChainPanel`**, and return it as `Backend.Widget` via
> a runtime cast — no `@_spi`, no framework patch?

This is the exact shape `GtkVideoView` already uses for GTK
(`Apps/linux-gtk/Sources/TailscreenViewerGtk/GtkVideoView.swift`, the
`guard backend is GtkBackend` downcast in `asWidget`, lines ~45–86). The
`WinUIVideoView` is the same file with `GtkBackend`→`WinUIBackend`,
`Gtk.GLArea`→`WinUI.SwapChainPanel`, and the GL draw call swapped for a D3D
present. The `else` branch of `GtkVideoView.asWidget` already returns a plain
container for non-GTK backends, so the two video views coexist cleanly (each
guards its own backend); a small `#if os(Windows)` or a shared protocol picks
the right one at the call site.

## The new video surface: `SwapChainPanel` + D3D11 YUV→RGB

`CGtkVideo` uploads three `GL_R8` plane textures and runs a BT.709 YUV→RGB
fragment shader into the `GtkGLArea`'s FBO. The Windows counterpart is a thin
C/C++ shim — call it `CSwapChainVideo` — doing the same with **Direct3D 11**:

- Create a `IDXGISwapChain1` bound to the `SwapChainPanel` (via
  `ISwapChainPanelNative::SetSwapChain`).
- Per frame: upload Y, U, V as three `DXGI_FORMAT_R8_UNORM` textures
  (`UpdateSubresource` / a staging `Map`), draw a fullscreen triangle with a
  pixel shader carrying the **same BT.709 matrix** as the GL shader
  (`cgtkvideo.c`'s `FS`), aspect-fit via the same `uXform`-style constants, and
  `Present`.
- The zoom/pan (`cgtkvideo_set_view`) and reset-on-context-loss
  (`cgtkvideo_reset`) entry points map 1:1 (D3D device-lost → recreate).

The C shim keeps Swift free of COM/D3D boilerplate, exactly as `CGtkVideo` keeps
it free of GL — `WinUIVideoView` just hands it plane pointers from
`FrameStore.current()`, mirroring `GtkVideoView.render`.

## Threading (unchanged model)

Identical to the GTK app's proven model: the `@MainActor` `TsnetTransport` Task
runs interleaved with the WinUI dispatcher loop; `present` → `FrameStore.set`
stashes the frame and requests a repaint marshalled to the **UI thread** —
`DispatcherQueue.TryEnqueue` in place of GTK's `g_idle_add`
(`cgtkvideo_queue_render`). GTK is only ever touched on its main thread; the same
rule holds for WinUI. `FrameStore`'s lock + value-type COW copy already makes the
cross-thread frame hand-off safe regardless of backend.

## Toolchain, build, CI

- **Swift on Windows** (swift.org toolchain) + the **Windows App SDK** that
  swift-cross-ui's `WinUIBackend` / `CWinAppSDK` targets.
- Build **`libtailscale.a` for Windows** (the Go c-archive; the Makefile's
  cross-build already produces per-arch archives for the mac universal binary —
  add a `windows/amd64` target) and **FFmpeg** libav* (vcpkg or the prebuilt
  shared libs), the two native deps the portable Swift links.
- A **new SwiftPM package** `Apps/windows` (sibling to `Apps/linux-gtk`), reusing
  `TailscreenViewerCore`/`TailscreenViewerTsnet` from `Apps/linux` and
  `TailscreenViewerGtk`'s **portable** pieces. `FrameStore` has already made
  that move — it now lives in TailscreenKit's `TailscreenViewer` target beside
  `ViewerSession`/`ViewerPipeline`, so the Windows app gets the frame hand-off
  without linking anything GTK. The rest (`ViewerUIState`, `ViewerControls`,
  `PickerModel`) should follow into a backend-neutral target so both apps share
  them without the GTK app pulling WinUI or vice versa. The video view +
  `CSwapChainVideo` are Windows-only targets.
- **CI:** a `windows-viewer` job on `windows-latest`: build the app; run a
  headless **D3D render self-test** using the **WARP** software rasterizer
  (`D3D_DRIVER_TYPE_WARP`) — the moral equivalent of the Linux job's Mesa
  `llvmpipe` — reading back the four colour-bar centres + the letterbox pixel,
  exactly like `cgtkvideo_selftest_check`. If WARP read-back proves flaky
  headless, fall back to a compile-only gate + a documented local render check
  (the live tsnet run is local-only on every platform anyway).

## Phased sub-delivery (when a Windows runner exists)

- **W0 — spike:** downstream `WinUIVideoView` compiles against stock
  `WinUIBackend`, hosts a `SwapChainPanel`, and renders one synthetic YUV frame
  with correct pixels via WARP read-back (retires the one risk, like the GTK
  spike).
- **W1 — live video:** wire the transport Task + frame marshalling; live decoded
  video from a real Mac sharer in a native WinUI window.
- **W2 — audio + chrome:** WASAPI `AudioSink`; the shared swift-cross-ui chrome
  (placards, control toolbar, picker) renders on WinUIBackend unchanged.
- **W3 — packaging:** MSIX / signed installer; a Release-workflow Windows leg.

## Risks

- **WinUIBackend maturity.** swift-cross-ui's WinUI backend is younger than its
  GTK one; the spike must confirm `SwapChainPanel` embedding and the `View`
  downcast before committing — same discipline that de-risked GTK.
- **D3D device-lost.** Windows can reset the GPU (driver update, sleep); the shim
  must handle `DXGI_ERROR_DEVICE_REMOVED` by recreating the device/swap chain
  (the `cgtkvideo_reset` hook already models context loss).
- **Headless render verification.** WARP should give deterministic pixels
  headless; if not, Windows render coverage degrades to local-only, and CI holds
  the compile gate — stated plainly rather than pretended around.

## Not started here

No Windows code is in this PR — it can neither compile nor run in the Linux
development/CI container (WinUIBackend is the pruned target). This document is
the L5 deliverable; W0–W3 land when a Windows toolchain + runner are available.
