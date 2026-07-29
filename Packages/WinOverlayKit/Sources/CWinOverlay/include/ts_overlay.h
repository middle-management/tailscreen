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
typedef struct ts_overlay ts_overlay;

/// Create the overlay covering a screen rectangle. NULL on failure.
///
/// **Call from a thread with a message pump.** It is a real window; without a
/// pump it will not repaint or respond to display changes. The app's UI thread
/// is the right place.
ts_overlay *ts_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height);

/// Replace the overlay's contents with a premultiplied BGRA bitmap, top-down,
/// tightly packed at `width * 4` bytes per row. Returns non-zero on success.
///
/// Safe from any thread.
int32_t ts_overlay_update(ts_overlay *overlay, const uint8_t *bgra, int32_t width,
                          int32_t height);

/// Show or hide without destroying. Hiding is how an empty canvas is
/// expressed — a fully transparent window still costs the compositor.
void ts_overlay_set_visible(ts_overlay *overlay, int32_t visible);

void ts_overlay_destroy(ts_overlay *overlay);

#ifdef __cplusplus
}
#endif

#endif /* TS_OVERLAY_H */
