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

#endif
