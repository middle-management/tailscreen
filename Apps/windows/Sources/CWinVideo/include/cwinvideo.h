#ifndef CWINVIDEO_H
#define CWINVIDEO_H
#include <stdint.h>

// D3D11 YUV->RGB for the Windows viewer. The sibling of `CGtkVideo`, and named
// to read alongside it: same function-per-concern split, same argument order,
// so a bug fixed in one is findable in the other.
//
// WHAT THIS DOES AND DELIBERATELY DOES NOT DO. It replaces exactly one thing:
// the per-frame CPU colour conversion (`I420Converter`) and the upload of the
// converted BGRA into a `WriteableBitmap`. It does NOT letterbox and does NOT
// zoom, because on Windows — unlike GTK — those are already free: the
// `SurfaceImageSource` is created at the video's own resolution and the XAML
// `Image` scales it, while zoom/pan is a `CompositeTransform` on the element
// that the compositor applies. Putting either in this shader would duplicate
// working GPU work, not move CPU work to the GPU.
//
// Every entry point must be called from the UI thread, which is where
// `WinUIVideoView` already polls `FrameStore`.

#ifdef __cplusplus
extern "C" {
#endif

// Create the D3D11 device and compile the shader. Idempotent; returns 1 on
// success, 0 if no device could be created (in which case the caller must keep
// its CPU fallback). BGRA support is requested because SurfaceImageSource
// requires it.
int32_t winvideo_init(void);

// Bind an `ISurfaceImageSourceNative` — pass the `IUnknown*` of the WinRT
// `SurfaceImageSource`; the QueryInterface happens here so no IID has to be
// spelled in Swift. Calls `SetDevice`. Returns 1 on success.
//
// Call again whenever the source is recreated (a resolution change): the
// previous binding is released first.
int32_t winvideo_bind_source(void *surface_image_source_unknown,
                             int32_t width, int32_t height);

// Draw a tightly-packed I420 frame (Y: w*h, U/V: ceil(w/2)*ceil(h/2)) into the
// bound source with a BT.709 limited-range shader.
//
// `overlay_bgra` is an optional **premultiplied BGRA** image the same size as
// the frame, composited over the video in the same pass — this is how
// annotations arrive, so they stay part of the picture and keep scaling with the
// element's transform exactly as they did when they were rasterized into the
// BGRA buffer. NULL when nobody is drawing, which is the common case and costs
// no upload.
//
// Both halves of that description are load-bearing and neither is checkable at
// compile time: the byte order is B,G,R,A because the portable
// `AnnotationRasterizer` writes what `UpdateLayeredWindow` wants, and the colour
// channels are already scaled by alpha. The shader's texture format and its
// composite each match one of those facts; changing the rasterizer means
// changing both.
//
// Returns 1 if a frame was presented, 0 otherwise (no binding, device lost — see
// `winvideo_device_lost`).
int32_t winvideo_draw_yuv(int32_t width, int32_t height,
                          const uint8_t *y, const uint8_t *u, const uint8_t *v,
                          const uint8_t *overlay_bgra);

// True (1) if the last draw failed because the D3D device was removed or reset.
// The caller's recovery is `winvideo_reset()` then `winvideo_init()` +
// `winvideo_bind_source()` again; a swap-chain-less path still loses its device
// on a driver update, and a viewer that goes black and stays black is worse than
// a slow one.
int32_t winvideo_device_lost(void);

// Fill the bound source with opaque black (no frame yet). Returns 1 on success.
int32_t winvideo_clear(void);

// Release the device, the shader and the source binding. The next `init` +
// `bind_source` rebuilds them.
void winvideo_reset(void);

// Render self-test: draw the supplied I420 frame, read four expected colour-bar
// centres back off the GPU and return 1 if all match within tolerance, else 0.
// Prints each sampled RGB plus a PASS/FAIL marker.
//
// The counterpart to `cgtkvideo_selftest_check`, and the reason WARP exists in
// CI: `D3D_DRIVER_TYPE_WARP` implements the same feature levels in software, so
// the shader is exercised on a runner with no GPU exactly as Xvfb + software GL
// does on Linux. Feed it `ColorBars` and both platforms are checked against one
// set of expected pixels — a mismatch means the two shaders disagree about
// BT.709 rather than that one of them is broken in isolation.
int32_t winvideo_selftest_check(int32_t width, int32_t height,
                                const uint8_t *y, const uint8_t *u,
                                const uint8_t *v);

#ifdef __cplusplus
}
#endif

#endif
