#ifndef CGTKVIDEO_H
#define CGTKVIDEO_H
#include <stdint.h>

// Draw a tightly-packed I420 frame (Y: w*h, U/V: ceil(w/2)*ceil(h/2)) with a
// BT.709 YUV->RGB shader. Lazily initialises the GL program/textures/VAO on
// first call. Must be called with a current GL context (inside a GtkGLArea
// render). glTexImage2D (re)allocates each call so a mid-stream resolution
// change is handled without a separate path.
//
// `full_range` selects the sample range: 0 for limited (16..235 luma), 1 for
// full (0..255). Pass what the DECODER reported for this frame — guessing
// crushes blacks on one kind of sharer or greys them out on the other. 0 is
// the codec-mandated default when a stream says nothing.
void cgtkvideo_draw_yuv(int32_t width, int32_t height,
                        const uint8_t *y, const uint8_t *u, const uint8_t *v,
                        int32_t full_range);

// Clear to black (when there's no frame yet).
void cgtkvideo_clear(void);

// Draw annotation strokes over the just-drawn video. Points are normalized
// [0,1] in the video content space (origin top-left), flattened x0,y0,x1,y1,…;
// `counts` holds the vertex count of each of `n_strokes` strokes in order;
// `rgba` is 4 floats (0..1) per stroke; `widths_px` is per-stroke line width in
// pixels (NULL ⇒ default). Maps each point through the SAME aspect-fit + zoom +
// pan transform the last `cgtkvideo_draw_yuv` used, so strokes track the video.
// Call inside the GLArea render, AFTER cgtkvideo_draw_yuv.
void cgtkvideo_draw_annotations(const float *norm_xy, const int *counts,
                                int n_strokes, const float *rgba,
                                const float *widths_px);

// Set the view transform applied on top of aspect-fit: `zoom` (≥1) scales the
// video about the centre, `pan_x`/`pan_y` shift it in NDC ([-1,1]). Defaults are
// 1 / 0 / 0 (plain aspect-fit). Driven from the viewer's zoom/pan state.
void cgtkvideo_set_view(float zoom, float pan_x, float pan_y);

// Drop cached GL objects so the next draw re-initialises them. Wire this to the
// GtkGLArea's create-context signal: GL object names are per-context, so a
// context teardown/recreate (unrealize→realize, reparent) must re-init.
void cgtkvideo_reset(void);

// Render self-test: read back the centres of four expected colour bars
// (white / black / red / blue) from the current framebuffer and return 1 if all
// match within tolerance, else 0. Prints each sampled RGB + a PASS/FAIL marker.
int32_t cgtkvideo_selftest_check(void);


// Request a repaint of the given GtkGLArea (pass its GtkWidget* — the GObject
// pointer is the same). Must be called on the GTK main thread. Forward-declares
// the one gtk symbol it needs so this GL-only target pulls no gtk headers.
void cgtkvideo_queue_render(void *gl_area_widget);

// Current allocated logical size of a GtkWidget (pass its GtkWidget*). Used by
// the input layer to normalize pointer coordinates against the live widget size
// — logical units, matching the logical coords GTK reports for motion/click, so
// the aspect-fit ratio math is HiDPI-independent. Writes 0 for a NULL widget.
void cgtkvideo_widget_size(void *widget, int32_t *out_w, int32_t *out_h);

// Make a widget focusable so an EventControllerKey attached to it receives key
// events. Call once at wiring time.
void cgtkvideo_widget_make_focusable(void *widget);

// Grab keyboard focus for a widget. Wire this to pointer-press so clicking the
// video surface directs subsequent keystrokes to it.
void cgtkvideo_widget_grab_focus(void *widget);

// Resize the widget's toplevel window to w×h (logical px). Walks up to the
// GtkRoot (the GtkWindow) and calls gtk_window_set_default_size — in GTK4 the
// sanctioned way to resize a mapped window. Used to grow the hub-sized window to
// the video's dimensions when the first frame arrives. No-op if the widget
// isn't in a window yet (call it from a render callback, where it is).
void cgtkvideo_resize_toplevel(void *widget, int32_t w, int32_t h);

// Scroll callback invoked from the native GtkEventControllerScroll (swift-cross-ui
// exposes no scroll-controller binding). `dx`/`dy` are the scroll deltas (GTK
// convention: dy > 0 scrolls down/away, dy < 0 up/toward the user); `mods` is the
// GdkModifierType bitmask at the event (bit 0 == GDK_SHIFT_MASK); `user` is the
// opaque context passed to cgtkvideo_attach_scroll. Runs on the GTK main thread.
typedef void (*cgtkvideo_scroll_cb)(double dx, double dy, unsigned int mods, void *user);

// Attach a native GtkEventControllerScroll (both axes) to a widget so scroll
// events reach Swift as zoom/pan input — swift-cross-ui has no EventControllerScroll
// binding, so this shim is the only way to observe scroll. Forward-declares the
// gtk/glib symbols it needs (resolved at final link, as with the render/widget
// helpers above) so this GL-only target pulls no gtk headers. The callback context
// is retained for the widget's lifetime (freed on controller finalize). Call once
// at wiring time; a no-op for a NULL widget.
void cgtkvideo_attach_scroll(void *widget, cgtkvideo_scroll_cb cb, void *user);

#endif
