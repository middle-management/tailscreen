#ifndef X11CAPTURE_H
#define X11CAPTURE_H

#include <stdint.h>

// C shim for X11 screen capture, keeping Swift free of XCB and SysV shared
// memory boilerplate — the same division of labour CGtkVideo uses to keep the
// GTK viewer free of OpenGL boilerplate.
//
// Capture goes through the MIT-SHM extension when the server offers it: the X
// server writes the frame straight into a shared segment, so a grab is a
// synchronisation round trip rather than a full-screen copy over the socket.
// Without MIT-SHM (a remote display, mainly) it falls back to xcb_get_image,
// which still works but pays a copy per frame.
//
// Conversion to I420 happens here too, for two reasons: it is a per-pixel loop
// that C compiles far better than Swift's bounds-checked arrays, and it keeps
// the pixel format contract (limited-range BT.709, matching the viewer's YUV
// shader) in one place next to the capture that produces it.

typedef struct x11cap x11cap_t;

// Connect to `display` (NULL uses $DISPLAY) and prepare to capture its root
// window. Returns NULL if the connection fails or the screen has no visual we
// can read as 32-bit Z-pixmap.
x11cap_t *x11cap_open(const char *display);

void x11cap_close(x11cap_t *cap);

// Root-window geometry at open time. X can resize a screen under us (RandR);
// `x11cap_grab_i420` reports that rather than writing past the caller's planes.
void x11cap_size(const x11cap_t *cap, int *width, int *height);

// Non-zero when the MIT-SHM zero-copy path is in use. Diagnostic only — the
// fallback produces identical pixels.
int x11cap_uses_shm(const x11cap_t *cap);

// Grab the current screen and convert into caller-owned I420 planes.
//
// `out_width`/`out_height` must be even and no larger than the captured
// screen; the top-left region of that size is used, which is how an odd screen
// dimension gets cropped to the even one an H.264 encoder requires. Planes are
// tightly packed: y is out_width*out_height, u and v are half of each
// dimension.
//
// Returns 0 on success, or:
//   -1 bad arguments (odd/oversized output, NULL planes)
//   -2 the grab failed (server gone, or the screen shrank under us)
int x11cap_grab_i420(x11cap_t *cap, uint8_t *y, uint8_t *u, uint8_t *v,
                     int out_width, int out_height);

// Convert one packed BGRA buffer to I420 with the same limited-range BT.709
// math `x11cap_grab_i420` uses. Exposed so the conversion can be tested
// without an X server — the capture half needs a display, this half doesn't.
void x11cap_bgra_to_i420(const uint8_t *bgra, int stride, uint8_t *y,
                         uint8_t *u, uint8_t *v, int width, int height);

#endif
