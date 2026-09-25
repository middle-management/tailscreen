# Plan: full GPU rendering on Windows and Linux

> Status: DONE. All steps landed. `Apps/windows/Sources/CWinVideo` +
> `WinUIVideoView` render YUV→RGB via a D3D11 shader into a
> `SurfaceImageSource` (not `SwapChainPanel` — see deviation below), matching
> Linux's existing `CGtkVideo` GL path. `winvideo-selftest` gates the shader
> on both arches with no GPU and no desktop. Follows `gpu-media-support.md`
> (encode/decode acceleration; this was the render/present half only).

## Problem

Linux (`CGtkVideo`) already uploaded YUV planes as GL textures and ran a
BT.709 shader — no CPU colour conversion. Windows (`WinUIVideoView`) did
`I420Converter.convert` per frame on the CPU (~7MP at 3360×2100) into a
`WriteableBitmap`, every frame, on the UI thread. The plan was one platform's
work: give Windows what Linux already had.

**Why tractable, not a rewrite:** `FrameStore` is the portable renderer
hand-off (nothing above it cares how pixels reach screen); `DecodedVideoFrame`
is already plane-shaped specifically so "a GPU shader does [the conversion]
for free"; `WinUIVideoView`'s header had already flagged `WriteableBitmap` as
a placeholder pending a GPU-backed source; and the letterbox/zoom/pan math
(`ViewerZoomMath`) is already shared and tested, just ported into the shader.

## Key design decisions

- **`CWinVideo` mirrors `CGtkVideo`'s function-per-concern shape exactly**
  (`winvideo_draw_yuv`, `winvideo_draw_annotations` as a second pass over the
  same transform, `winvideo_set_view`, etc.) so a bug found in one platform's
  shader is findable in the other's.
- **Deviation from the original sketch: `SurfaceImageSource`, not
  `SwapChainPanel`.** swift-winui 0.2.1 has no `SwapChainPanel` binding at
  all, and `WinUIElementRepresentable` needs a Swift-typed element to host —
  generating the missing binding was ruled out as upstream work on a
  third-party dependency, a poor thing to put underneath a rendering change.
  `SurfaceImageSource` *is* bound, and its `ISurfaceImageSourceNative` hands
  back an `IDXGISurface` the D3D11 device renders into — the WinUI element
  stays plain `Image`; everything else (representable, polling, zoom/
  annotation/remote-control wiring) is untouched. Accepted trade-off:
  `SurfaceImageSource` is XAML-composited, giving up the last hop of a
  `SwapChainPanel`'s efficiency — not where the actual cost was (CPU
  conversion + upload, eliminated either way). Revisit only with a profiling
  number in hand.
- **Device-loss handling is its own step, not folded into the D3D11 device
  work**, because it's a new failure mode `WriteableBitmap` never had:
  `DXGI_ERROR_DEVICE_REMOVED`/`DEVICE_RESET` from `BeginDraw` must rebuild the
  device, the `SurfaceImageSource` binding and the textures, then redraw from
  `FrameStore.current()` — a viewer that goes black on a driver update and
  stays black is worse than one that's merely slow.
- **CI-gated with no GPU, via WARP** (`D3D_DRIVER_TYPE_WARP`, a software
  rasterizer implementing the same feature levels) — `winvideo-selftest`
  links `CWinVideo` alone (no WinUI, no window/desktop/package identity) and
  exercises the real shader on a GPU-less runner. `makeColorBarsFrame()` was
  moved into the portable `TailscreenViewer` tier so both platforms assert
  against one shared synthetic frame.
- **Self-test assertions had to be relative predicates** (`white > 200`,
  `r > b + 60`, etc.), not exact RGB triples — the first cut used wrong
  expected values (ColorBars' bars are chosen for BT.709 unambiguity, not
  round numbers) that would have failed a *correct* render and invited
  "fixing" the shader to match a bad constant. GL's letterbox assertion was
  deliberately dropped (this shader does no geometry).
- **The self-test also renders an overlay pass**, added after discovering the
  video-only version would have passed two real shipped defects: an overlay
  texture format mismatched with `AnnotationRasterizer`'s byte order, and
  alpha multiplied twice on already-premultiplied data. Both are wrong
  pictures, not build errors — only a pixel check catches them.

## What this deliberately did not do

Touch Linux's GL upload strategy (separate optimization, own measurement);
pursue zero-copy decode (the payoff *after* this landed — `gpu-media-support.md`
can now hand a `d3d11va` surface straight to the renderer); or change
annotation hit-testing / remote-control pointer mapping (both are
renderer-independent via `ViewerZoomMath`/`WindowsPointerMapping`, but needed
re-verification once the letterbox transform moved into a shader — two
independent letterbox computations is a classic way for clicks to land a few
pixels off).

## Pointers

- `Apps/windows/Sources/CWinVideo` (D3D11 shader, mirrors `CGtkVideo`).
- `Apps/windows/Sources/tailscreen/WinUIVideoView.swift` (source swap,
  device-loss rebuild — see its header for the full `SurfaceImageSource`
  reasoning).
- `winvideo-selftest` target + `app-windows.yml`'s "Render self-test (WARP)"
  step (the CI proof).
- `gpu-media-support.md` (the encode/decode half; established the pipeline
  state this plan builds on).

## How it was verified

`FrameRateCounter` shows materially higher sustained fps and lower CPU on a
Mac→Windows session at 3360×2100 — visible even under a VM test machine
(unlike hardware decode), since it removes CPU work rather than depending on
a hardware decode block the VM doesn't expose.
