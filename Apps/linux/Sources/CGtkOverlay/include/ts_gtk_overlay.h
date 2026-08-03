#ifndef TS_GTK_OVERLAY_H
#define TS_GTK_OVERLAY_H
#include <stdint.h>

// The Linux sharer's annotation overlay: a click-through, always-on-top window
// showing the strokes viewers draw, on the sharer's own screen.
//
// The counterpart of WinOverlayKit on Windows and SharerOverlayWindow on
// macOS, and deliberately the same shape as the former: the two halves worth
// testing — WHAT should be visible (`ReceivedAnnotations`) and how to draw it
// (`AnnotationRasterizer`) — live in the portable tier, and what is left here
// is window lifetime, which no unit test could check anyway.
//
// The pixel contract is the same as Windows': premultiplied BGRA, because
// `AnnotationRasterizer` emits that for `UpdateLayeredWindow` and cairo's
// CAIRO_FORMAT_ARGB32 is byte-for-byte the same thing on a little-endian host
// (cairo names its formats by 32-bit word, so 0xAARRGGBB in a word is B,G,R,A
// in memory). So there is no conversion step — and the claim is checked rather
// than assumed: `tailscreen --overlay-self-test` draws a RED stroke and reads
// the screen back, which fails loudly if the channel order is wrong.

#ifdef __cplusplus
extern "C" {
#endif

// Whether this session can host the overlay at all.
//
// Two conditions, and the second is the interesting one: a display, AND a
// running compositing manager. Without compositing an X11 window has no alpha
// — the parts we leave transparent are painted as opaque black — so the
// "overlay" would be a black rectangle over the sharer's screen, which is
// worse than having no annotations at all. A host that answers 0 here must
// pass `rendersAnnotations: false` so viewers hide their drawing tools instead
// of drawing into a void, the same capability-honesty rule the rest of the
// sharer follows.
//
// Must be called after GTK is initialised (i.e. from inside the app), because
// the answer comes from the open display.
int32_t ts_gtk_overlay_supported(void);

// Create the overlay covering `w`x`h` at root coordinates (`x`, `y`).
// Returns NULL if the window could not be created — a share without
// annotations is a smaller loss than a share that refuses to start.
//
// GTK main thread only. The window starts hidden; the first
// `ts_gtk_overlay_update` shows it.
void *ts_gtk_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height);

// Replace the overlay's pixels and show it.
//
// `bgra` is premultiplied BGRA, `stride` bytes per row. The bytes are COPIED,
// so the caller may reuse its buffer the moment this returns — which is what
// makes this callable from the server's control-channel thread, where
// annotations actually arrive. The repaint itself is marshalled onto the GTK
// main thread; calling any GTK function directly from that thread would be a
// crash, not a glitch.
void ts_gtk_overlay_update(void *handle, const uint8_t *bgra, int32_t stride,
                           int32_t width, int32_t height);

// Let the SHARER draw on the overlay, rather than only watching viewers draw.
//
// Arming swaps the empty input region for a full one, so pointer events land
// on the overlay instead of passing through. That is the feature — and it is
// also a trap, because this window is override-redirect and covers the whole
// capture region: the moment it is armed, every control underneath it,
// including Tailscreen's own "stop drawing" button, is unreachable by mouse.
//
// So **Escape is the way out, and arming fails if Escape cannot work.** An
// override-redirect window is invisible to the window manager, which therefore
// never gives it focus; focus has to be taken explicitly. This returns 0 if
// that did not happen, and the caller must then stay disarmed and say so. A
// drawing mode nobody can leave is worse than no drawing mode.
//
// Returns 1 when the requested state was reached (including any disarm, which
// cannot fail). GTK main thread only.
int32_t ts_gtk_overlay_set_interactive(void *handle, int32_t on);

// Where the sharer's pointer went while armed.
//
// `phase` is 0 = pressed, 1 = dragged, 2 = released. `x`/`y` are normalized
// `[0,1]` over the overlay — the same space `Annotation` uses, so no host has
// to know the capture region's pixel size.
//
// `on_escape` fires when the sharer presses Escape, and means "disarm now".
// The callbacks run on the GTK main thread. Set before arming; pass NULL
// pointers to clear.
void ts_gtk_overlay_set_input_callbacks(
    void *handle, void *ctx,
    void (*on_pointer)(void *ctx, int32_t phase, double x, double y),
    void (*on_escape)(void *ctx));

// Hide the window (nobody is drawing). Callable from any thread.
//
// Hidden rather than left fully transparent: a transparent window still costs
// the compositor on every frame of whatever is beneath it, and a share spends
// almost all of its life with nobody drawing.
void ts_gtk_overlay_hide(void *handle);

// Destroy the window. Callable from any thread — the teardown is posted to
// the main loop, because the last owner can genuinely be a network thread.
void ts_gtk_overlay_destroy(void *handle);

#ifdef __cplusplus
}
#endif

#endif
