# Plan: full GPU rendering on Windows and Linux

Follows `gpu-media-support.md`, which established the pipeline state and closed
the FFmpeg capability question. This is the render half only — colour conversion
and present. Encode and decode acceleration are tracked there.

## Where the two platforms actually stand

**Linux is already done, and it is the reference.** `GtkVideoView` hands the
`FrameStore` frame's three planes to a C shim:

```c
void cgtkvideo_draw_yuv(int32_t width, int32_t height,
                        const uint8_t *y, const uint8_t *u, const uint8_t *v);
```

`CGtkVideo` uploads them as textures and runs a BT.709 YUV→RGB shader inside a
`Gtk.GLArea`, letterboxing and applying zoom/pan in the shader. Annotations are a
second pass (`cgtkvideo_draw_annotations`) that reuses the same transform so
strokes track the video. No CPU colour conversion anywhere on this path.

**Windows is the only CPU path left.** `WinUIVideoView` calls
`I420Converter.convert(frame, into: bytes)` per frame and uploads BGRA into a
`WriteableBitmap` behind a WinUI `Image`. At 3360×2100 that is ~7 MP converted on
the CPU plus a full-frame upload, every frame, on the UI thread.

So "full GPU rendering on Windows and Linux" is, concretely, **one platform's
work**: give Windows what Linux has. That is the whole plan, and the pieces it
needs already exist.

## Why this is tractable rather than a rewrite

Three seams are already in place and were built with this in mind:

1. **`FrameStore`** is the portable hand-off — `set` / `current` / `setRedraw` —
   and both renderers already poll it. Nothing above the renderer knows or cares
   how pixels reach the screen.
2. **`DecodedVideoFrame` is plane-shaped, deliberately.** `FFmpegKit`'s own
   comment says the planes are exposed with decoder padding removed "so a
   renderer can upload them", and that conversion "is not the decoder's job — a
   GPU shader does it for free". The data is already in the shape a GPU wants.
3. **`WinUIVideoView`'s header states the intended replacement**: `Image` +
   `WriteableBitmap` was chosen as the debuggable first answer, and because the
   hand-off is `FrameStore`, "a later `SwapChainPanel` implementation replaces
   this file without touching the decoder, the session, or the transport."

And `CGtkVideo` is an existence proof of the whole shape: a small C library with
a `draw_yuv(width, height, y, u, v)` entry point, a second entry point for
annotations sharing the transform, and a Swift view that owns nothing but the
polling.

## The work

### Step 1 — `CWinVideo`: a D3D11 sibling of `CGtkVideo`

A C (or C++) target mirroring `CGtkVideo`'s interface as closely as the API
allows:

```
winvideo_init(void *swapChainPanelNative)   // bind to the panel
winvideo_draw_yuv(w, h, y, u, v)            // 3 textures + YUV→RGB shader
winvideo_draw_annotations(...)              // second pass, same transform
winvideo_clear()                            // black, no frame yet
winvideo_resize(w, h)                       // swap-chain buffers
```

Deliberately the same function-per-concern split, so the two platforms can be
read side by side and a bug fixed in one is findable in the other.

Contents: `ID3D11Device` + swap chain via `IDXGIFactory2::CreateSwapChainForComposition`,
three `R8_UNORM` textures (one per plane), a pixel shader doing BT.709 limited-range
YUV→RGB, and the same letterbox/zoom/pan maths the GL shader already has —
**ported, not reinvented**, since `ViewerZoomMath` is already portable and tested
and the GL version is the working reference.

### Step 2 — `WinUIVideoView` swaps its element

`WinUIElementRepresentable` already lets any `FrameworkElement` be hosted; today
it hosts `WinUI.Image`, and it would host `WinUI.SwapChainPanel` instead. The
polling, the `generation` bump, the zoom/annotation/remote-control wiring and the
`FrameStore` read all stay. `I420Converter` and the `WriteableBitmap` go.

The file's own comment promises this is a one-file change. This step is where
that promise gets tested.

### Step 3 — the failure mode the current path does not have

`WriteableBitmap` cannot lose its device. A swap chain can, and must handle it:
`DXGI_ERROR_DEVICE_REMOVED` / `DEVICE_RESET` means tearing down and rebuilding
device, swap chain and textures, then redrawing from `FrameStore.current()`.

This is the main genuinely new risk in the plan, and it is why the step exists
separately rather than being folded into step 1. A viewer that goes black on a
driver update and stays black is worse than one that is merely slow.

### Step 4 — prove it, in CI, without a GPU

The `--ui-preview-video` mode and the existing screenshot jobs already exist for
this. Add a Windows screenshot of the video surface showing a known synthetic
frame — the Linux side already has `ColorBars.swift`, "YUV values chosen so a
BT.709 shader yields unambiguous colours", plus a headless render self-test under
Xvfb with software GL.

Windows equivalent: WARP (`D3D_DRIVER_TYPE_WARP`) is a software rasteriser that
implements the same D3D11 feature levels, so the shader can be exercised on a
GPU-less runner exactly as Xvfb+software-GL does on Linux. **Reuse `ColorBars`**
— the same expected pixels on both platforms is the point, and a mismatch would
mean the two shaders disagree about BT.709.

## Sequencing and risk

| Step | Risk | Rollback |
|---|---|---|
| 1 `CWinVideo` | Medium — new D3D11 code, but no product change until step 2 | Nothing shipped |
| 2 View swap | Low — one file, seam designed for it | Revert the file |
| 3 Device-lost | Medium — hard to trigger deliberately | Keep the rebuild path behind a log line so it is visible in the wild |
| 4 CI proof | Low | — |

Steps 1 and 4 can proceed in parallel with the encode/decode work in
`gpu-media-support.md`; step 2 is the only one that changes what a user sees.

## What this plan does not do

- **It does not touch Linux.** Linux already renders on the GPU. If GL upload
  strategy (PBOs, texture reuse) turns out to matter, that is a separate
  optimisation with its own measurement, not part of "get to GPU rendering".
- **It does not pursue zero-copy decode.** That is the payoff *after* this lands:
  once Windows has a D3D11 renderer, a `d3d11va` hardware decoder can hand its
  surface straight to it. Doing it before there is a GPU renderer would mean
  pulling the frame back to the CPU, which is the point made in
  `gpu-media-support.md`.
- **It does not use `SwapChainPanel` for the annotation overlay's hit-testing or
  the remote-control pointer mapping.** Those go through `ViewerZoomMath` and
  `WindowsPointerMapping` on normalized coordinates and are renderer-independent
  by construction — but the mapping must be re-verified once the transform moves
  into a shader, because a letterbox computed in two places is a classic way for
  clicks to land a few pixels off.

## How we will know it worked

- The `⚠ no video decoded yet` heartbeat is unaffected — this changes nothing
  upstream of the decoder. Success is measured on the *other* side.
- `FrameRateCounter` already feeds the stats HUD; a Mac→Windows session at
  3360×2100 should show a materially higher sustained fps and lower CPU.
- Unlike hardware decode, **this benefit should be visible under UTM**, because
  it removes CPU work and a CPU→GPU copy rather than depending on a hardware
  decode block the VM does not expose. That is why it is worth doing even though
  the test machine is a VM.
