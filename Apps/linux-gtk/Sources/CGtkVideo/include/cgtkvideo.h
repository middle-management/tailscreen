#ifndef CGTKVIDEO_H
#define CGTKVIDEO_H
#include <stdint.h>

// Draw a tightly-packed I420 frame (Y: w*h, U/V: (w/2)*(h/2)) with a BT.709
// YUV->RGB shader. Lazily initialises the GL program/textures/VAO on first call.
// Must be called with a current GL context (i.e. inside a GtkGLArea render).
void cgtkvideo_draw_yuv(int32_t width, int32_t height,
                        const uint8_t *y, const uint8_t *u, const uint8_t *v);

// Clear to black (when there's no frame yet).
void cgtkvideo_clear(void);

// Render self-test: read back the centres of four expected colour bars
// (white / black / red / blue) from the current framebuffer and return 1 if all
// match within tolerance, else 0. Prints each sampled RGB to stderr.
int32_t cgtkvideo_selftest_check(void);

#endif
