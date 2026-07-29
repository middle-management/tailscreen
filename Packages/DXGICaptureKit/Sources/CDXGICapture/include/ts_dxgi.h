// ts_dxgi.h — a flat C surface over DXGI Desktop Duplication.
//
// Screen capture for the Windows sharer's `CaptureEncoding` backend: the
// counterpart of X11CaptureKit on Linux and ScreenCaptureKit on macOS. Like
// those, it produces BGRA and nothing more — the BGRA→I420 conversion lives in
// `BGRAToI420` in the portable tier, where Linux CI tests it against the
// viewer's inverse.
//
// Desktop Duplication rather than Windows.Graphics.Capture: WGC is the modern
// API and can capture a single window, but it is WinRT, needs a
// `GraphicsCaptureItem` obtained through a picker, and draws a yellow border
// the user cannot disable on older builds. Duplication is plain COM, captures a
// whole output, and has no UI — which matches what the Linux sharer already
// does (root window only) and what the seam already expects.
//
// Everything here is `#ifdef _WIN32`; elsewhere the translation unit is empty
// so the package still builds wherever the rest of the repo is built.

#ifndef TS_DXGI_H
#define TS_DXGI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque duplication session: the D3D11 device, the output duplication, and
/// the staging texture frames are copied into for CPU read.
typedef struct ts_dxgi ts_dxgi;

enum {
    TS_DXGI_OK = 0,
    /// A null pointer or a nonsense output index.
    TS_DXGI_ERR_ARGUMENT = -1,
    /// No new frame within the timeout. **Not an error** — Duplication only
    /// produces a frame when the desktop actually changes, so a static screen
    /// times out continuously and the caller should re-encode what it already
    /// has rather than treat this as a failure.
    TS_DXGI_TIMEOUT = -2,
    /// The duplication was invalidated: a resolution or mode change, a GPU
    /// switch, DWM restarting, or the secure desktop (a UAC prompt) taking
    /// over. Recoverable by closing and reopening — the caller decides whether
    /// to, since the desktop may be gone for good.
    TS_DXGI_ERR_LOST = -3,
    /// The adapter reported no output at that index.
    TS_DXGI_ERR_NO_OUTPUT = -4,
    /// A frame is already mapped; release it before acquiring another.
    TS_DXGI_ERR_BUSY = -5,
};

/// Open a duplication of one output and prepare a staging texture for it.
///
/// - output_index: 0 is the primary display. Multi-monitor selection is the
///   caller's business; this does not enumerate for it.
/// - width, height: receive the output's pixel dimensions.
int32_t ts_dxgi_open(ts_dxgi **out, uint32_t output_index, uint32_t *width, uint32_t *height);

/// Wait up to `timeout_ms` for a new desktop frame and map it for reading.
///
/// On TS_DXGI_OK the caller owns the mapping until ``ts_dxgi_release`` — the
/// pointer is valid only until then, and only one frame may be mapped at a
/// time.
///
/// - bgra: receives the mapped pixels.
/// - stride: receives the ROW PITCH in bytes, which is the driver's and is
///   routinely wider than `width * 4`. Reading at `width * 4` skews the image
///   further with every row.
int32_t ts_dxgi_acquire(
    ts_dxgi *handle, uint32_t timeout_ms, const uint8_t **bgra, int32_t *stride);

/// Unmap the frame from the last successful ``ts_dxgi_acquire``. Safe to call
/// when nothing is mapped.
void ts_dxgi_release(ts_dxgi *handle);

/// Release the duplication and everything under it. Safe on NULL.
void ts_dxgi_close(ts_dxgi *handle);

#ifdef __cplusplus
}
#endif

#endif  // TS_DXGI_H
