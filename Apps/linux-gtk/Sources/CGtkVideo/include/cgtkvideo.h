#ifndef CGTKVIDEO_H
#define CGTKVIDEO_H
#include <stdint.h>

// Draw a tightly-packed I420 frame (Y: w*h, U/V: ceil(w/2)*ceil(h/2)) with a
// BT.709 YUV->RGB shader. Lazily initialises the GL program/textures/VAO on
// first call. Must be called with a current GL context (inside a GtkGLArea
// render). glTexImage2D (re)allocates each call so a mid-stream resolution
// change is handled without a separate path.
void cgtkvideo_draw_yuv(int32_t width, int32_t height,
                        const uint8_t *y, const uint8_t *u, const uint8_t *v);

// Clear to black (when there's no frame yet).
void cgtkvideo_clear(void);

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

#endif
