#ifndef TS_OVERLAY_H
#define TS_OVERLAY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A click-through, always-on-top, per-pixel-alpha window for drawing viewer
/// annotations over the sharer's own screen.
///
/// `UpdateLayeredWindow` is the whole reason this is small: it takes a
/// premultiplied BGRA bitmap and composites it, so there is no drawing API to
/// wrap — the rasterizing happens in Swift (`AnnotationRasterizer`), where
/// Linux CI can test it, and this only owns the window.
///
/// **The overlay owns a thread**, and that is the substance of this file. A
/// window belongs to the thread that created it, and every state change — show,
/// hide, and the `SetWindowPos` inside `UpdateLayeredWindow` — is delivered to
/// that thread's message queue. A window whose thread never pumps is a window
/// Windows treats as hung: calls from other threads block until they time out
/// (five seconds each), and the window is destroyed outright if the creating
/// thread ever exits. Annotations arrive on a network thread, which is neither
/// the UI thread nor a thread that pumps, so the overlay runs its own pump and
/// every entry point below is a post to it.
typedef struct ts_overlay ts_overlay;

/// Create the overlay covering a screen rectangle. NULL on failure.
///
/// Safe from any thread: the window is created on the overlay's own thread and
/// this waits for that to finish, so the returned handle is ready to use.
///
/// Coordinates are virtual-desktop pixels. The process must be per-monitor DPI
/// aware (`ts_input_enable_per_monitor_dpi`, in SendInputKit) or these are the
/// *scaled* coordinates a DPI-unaware process sees, and the overlay lands in
/// the wrong place on any display that isn't at 100%.
ts_overlay *ts_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height);

/// Replace the overlay's contents with a premultiplied BGRA bitmap, top-down,
/// tightly packed at `width * 4` bytes per row, and show it.
///
/// Returns non-zero once the update has been handed to the overlay's thread —
/// the compositing happens there, so this never blocks on the window. Safe from
/// any thread.
int32_t ts_overlay_update(ts_overlay *overlay, const uint8_t *bgra, int32_t width,
                          int32_t height);

/// Hide without destroying. This is how an empty canvas is expressed — a fully
/// transparent window still costs the compositor on every frame beneath it.
///
/// There is no matching show: making the overlay visible is implicit in
/// `ts_overlay_update`, which has pixels to show. An empty overlay should never
/// be visible, so it cannot be asked to be.
void ts_overlay_hide(ts_overlay *overlay);

void ts_overlay_destroy(ts_overlay *overlay);

#ifdef __cplusplus
}
#endif

#endif /* TS_OVERLAY_H */
