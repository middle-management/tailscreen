# Plan: full GPU rendering on Windows and Linux

> **Status: DONE.** All four steps landed. `Apps/windows/Sources/CWinVideo`
> exists, `WinUIVideoView` feeds a `SurfaceImageSource` from its D3D11 YUV→RGB
> shader (not the `WriteableBitmap` + `I420Converter` path this plan was written
> against), annotations composite in the same pass as an RGBA overlay, and
> `winvideo-selftest` gates the shader on both arches with no GPU and no desktop.
> One deviation from the sketch below: the image source is `SurfaceImageSource`
> rather than `SwapChainPanel`, because swift-winui projects no Swift-typed
> `SwapChainPanel` element — see `WinUIVideoView`'s header for that reasoning and
> for the device-lost recovery a `WriteableBitmap` never needed.
>
> Kept for the rationale: why the seams made this tractable, and what the CI gate
> can and cannot prove. **The tenses below are as-written and describe the
> pre-GPU state.**

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
winvideo_init(void)                         // D3D11 device + shader
winvideo_bind_source(void *surfaceImageSourceNative)
winvideo_draw_yuv(w, h, y, u, v)            // 3 textures + YUV→RGB shader
winvideo_draw_annotations(...)              // second pass, same transform
winvideo_clear()                            // black, no frame yet
winvideo_set_view(zoom, pan_x, pan_y)       // mirrors cgtkvideo_set_view
winvideo_reset(void)                        // drop device objects, re-init next draw
```

Deliberately the same function-per-concern split, so the two platforms can be
read side by side and a bug fixed in one is findable in the other.

Contents: a BGRA-capable `ID3D11Device` (which `SurfaceImageSource` requires),
three `R8_UNORM` textures (one per plane), a pixel shader doing BT.709 limited-range
YUV→RGB rendered into the `IDXGISurface` that
`ISurfaceImageSourceNative::BeginDraw` returns, and the same letterbox/zoom/pan maths the GL shader already has —
**ported, not reinvented**, since `ViewerZoomMath` is already portable and tested
and the GL version is the working reference.

### Step 2 — `WinUIVideoView` swaps its image SOURCE, not its element

**Corrected after checking the dependency.** This step originally said to host
`WinUI.SwapChainPanel` instead of `WinUI.Image`. That is not available:
**swift-winui 0.2.1 has no `SwapChainPanel` binding at all** — zero occurrences
across `Sources/WinUI/` — while `WinUI.Image` is bound
(`Microsoft.UI.Xaml.Controls.swift:6122`). `WinUIElementRepresentable` needs a
Swift-typed `WinUIElementType`, so a panel we cannot name in Swift cannot be
hosted, and the C++ side cannot supply one either.

Generating the missing binding is possible in principle — swift-winui is
generated from WinMD — but that is upstream work on a third-party dependency,
which is a poor thing to put underneath a rendering change.

**What is available, and is bound:** `SurfaceImageSource` (and
`VirtualSurfaceImageSource`, and `WriteableBitmap`, and `SoftwareBitmapSource`).
`microsoft.ui.xaml.media.dxinterop.h` — the header declaring
`ISwapChainPanelNative` *and* `ISurfaceImageSourceNative` — ships inside the
dependency at `Sources/CWinAppSDK/nuget/include/`, so the native interfaces are
reachable from a C/C++ target.

So the element stays `WinUI.Image` and the **source** changes:
`WriteableBitmap` → `SurfaceImageSource`, whose `ISurfaceImageSourceNative`
hands us an `IDXGISurface` from `BeginDraw`, which the D3D11 device from step 1
renders the YUV→RGB pass into before `EndDraw`.

Everything the plan wanted survives: three plane textures, a BT.709 shader, no
CPU colour conversion, no CPU upload of a converted frame. The representable, the
polling, the `generation` bump and the zoom/annotation/remote-control wiring are
all untouched — this is a smaller change than the original step, not a bigger one.

**The honest trade-off:** `SurfaceImageSource` is composed by XAML rather than
presented as an independent swap chain, so it gives up the last hop of a
`SwapChainPanel`'s efficiency. That hop is not where the cost is — the cost is
~7 MP of CPU colour conversion plus a full-frame CPU→GPU upload per frame, and
both of those go away either way. If profiling later shows XAML composition is
the remaining bottleneck, the answer is to get a `SwapChainPanel` binding
upstream, with a measurement in hand to justify it.

### Step 3 — the failure mode the current path does not have

`WriteableBitmap` cannot lose its device. A D3D11 device can, and must handle it:
`BeginDraw` returns `DXGI_ERROR_DEVICE_REMOVED` / `DEVICE_RESET`, which means
rebuilding the device, the `SurfaceImageSource` binding and the textures, then
redrawing from `FrameStore.current()`.

This is the main genuinely new risk in the plan, and it is why the step exists
separately rather than being folded into step 1. A viewer that goes black on a
driver update and stays black is worse than one that is merely slow.

### Step 4 — prove it, in CI, without a GPU — **DONE**

Landed as `winvideo-selftest`, an executable target beside `tsnet-probe` (a CI
diagnostic, not a shipped app), plus a `Build the render self-test` /
`Render self-test (WARP)` step pair in `app-windows.yml`. It links `CWinVideo`
and no WinUI, so it needs no window, no desktop session and no package identity;
`winvideo_init`'s existing HARDWARE→WARP fallback means a GPU-less runner
exercises the real shader with nothing to configure. Exit codes carry the
diagnosis: 0 pass, 3 wrong pixels, 2 no D3D11 device at all (a runner-image
regression, not ours).

`makeColorBarsFrame()` moved from `Apps/linux/Sources/TailscreenViewerGtk/` into
the portable `TailscreenViewer` tier so both platforms assert against one frame
— the same trip `FrameRateCounter` made when Windows needed it.

**Two corrections found while implementing, both of which would have made this
step lie.**

First, the Windows check's expectations were wrong, and wrong in the direction
that fails a *correct* render: it expected the four bars at
{235,235,235}/{16,16,16}/{235,16,16}/{16,16,235} within ±24. ColorBars' third bar
is Y=128,U=128,V=255 — not saturated red but a mid-luma maximum-Cr colour, which
BT.709 puts at rgb(255,63,130), 47 away on green; the fourth lands at
rgb(130,103,255). Wired up as written, CI would have gone red and the obvious
"fix" would have been to bend the shader to match a bad constant. It now asserts
the same *relative predicates* `cgtkvideo_selftest_check` uses (`white > 200`,
`black < 60`, `r > 180 ∧ r > b + 60`, `b > 180 ∧ b > r + 60`), which is what
"reuse ColorBars" actually has to mean. The GL side's letterbox assertion is
deliberately NOT carried over: this shader does no geometry, so there is no
letterbox to find.

Second, the check now also renders an **overlay** pass, because the version that
only checked the video bars would have passed both real defects this work
shipped — the overlay texture declared `R8G8B8A8` while `AnnotationRasterizer`
writes b,g,r,a, and the composite multiplying by alpha twice on premultiplied
data. Neither is a build error; both are wrong pictures. One half-transparent
premultiplied red patch over the black bar catches both: correct gives r=128,
double-multiplied alpha gives 64 (fails `r > 100`), swapped channels puts the 128
in blue (fails `r > b + 60`).

### The original sketch of step 4

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
- **It does not change the annotation overlay's hit-testing or the
  remote-control pointer mapping.** Those go through `ViewerZoomMath` and
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
