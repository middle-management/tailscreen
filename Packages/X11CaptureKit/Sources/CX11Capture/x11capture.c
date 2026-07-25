#include "include/x11capture.h"

#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <xcb/shm.h>
#include <xcb/xcb.h>

struct x11cap {
    xcb_connection_t *conn;
    xcb_window_t root;
    int width;
    int height;
    int use_shm;
    xcb_shm_seg_t seg;
    int shmid;
    uint8_t *shmaddr;
    // Fallback buffer for the non-SHM path, allocated once.
    uint8_t *fallback;
};

static void detach_shm(x11cap_t *c) {
    if (!c->use_shm) return;
    xcb_shm_detach(c->conn, c->seg);
    if (c->shmaddr) shmdt(c->shmaddr);
    c->shmaddr = NULL;
    c->use_shm = 0;
}

x11cap_t *x11cap_open(const char *display) {
    x11cap_t *c = calloc(1, sizeof(*c));
    if (!c) return NULL;

    c->conn = xcb_connect(display, NULL);
    if (!c->conn || xcb_connection_has_error(c->conn)) {
        if (c->conn) xcb_disconnect(c->conn);
        free(c);
        return NULL;
    }

    const xcb_setup_t *setup = xcb_get_setup(c->conn);
    xcb_screen_t *screen = xcb_setup_roots_iterator(setup).data;
    if (!screen || screen->root_depth < 24) {
        xcb_disconnect(c->conn);
        free(c);
        return NULL;
    }
    c->root = screen->root;
    c->width = screen->width_in_pixels;
    c->height = screen->height_in_pixels;

    size_t bytes = (size_t)c->width * (size_t)c->height * 4;

    // MIT-SHM: the server renders into memory we both map, so a grab costs a
    // round trip instead of a full-screen transfer over the X socket.
    xcb_shm_query_version_reply_t *v =
        xcb_shm_query_version_reply(c->conn, xcb_shm_query_version(c->conn), NULL);
    if (v) {
        free(v);
        c->shmid = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600);
        if (c->shmid >= 0) {
            c->shmaddr = shmat(c->shmid, NULL, 0);
            if (c->shmaddr != (uint8_t *)-1) {
                c->seg = xcb_generate_id(c->conn);
                xcb_shm_attach(c->conn, c->seg, (uint32_t)c->shmid, 0);
                c->use_shm = 1;
            } else {
                c->shmaddr = NULL;
            }
            // Mark for destruction now: the segment lives until both we and
            // the server detach, so this can't leak if we crash.
            shmctl(c->shmid, IPC_RMID, 0);
        }
    }

    if (!c->use_shm) {
        c->fallback = malloc(bytes);
        if (!c->fallback) {
            xcb_disconnect(c->conn);
            free(c);
            return NULL;
        }
    }
    return c;
}

void x11cap_close(x11cap_t *c) {
    if (!c) return;
    detach_shm(c);
    free(c->fallback);
    if (c->conn) xcb_disconnect(c->conn);
    free(c);
}

void x11cap_size(const x11cap_t *c, int *width, int *height) {
    if (!c) return;
    if (width) *width = c->width;
    if (height) *height = c->height;
}

int x11cap_uses_shm(const x11cap_t *c) { return c ? c->use_shm : 0; }

// Limited-range BT.709, matching the viewer's YUV→RGB shader
// (Apps/linux-gtk/Sources/CGtkVideo/cgtkvideo.c) exactly: luma 16..235, chroma
// 128±112. Getting the range wrong here doesn't fail loudly — it just washes
// out or crushes every frame — so the two must be changed together.
//
// Fixed point at 1/16384. Y_full uses the BT.709 luma weights (0.2126,
// 0.7152, 0.0722); the scale to studio swing and the chroma normalisation
// (0.4734 = (224/255)/1.8556, 0.5578 = (224/255)/1.5748) are folded in.
#define FX 14
// Round-to-nearest rather than truncate: without it white lands on 234
// instead of the studio-swing ceiling of 235, and every level below it is
// biased dark by the same fraction.
#define FXR (1 << (FX - 1))
#define C_YR 3483
#define C_YG 11718
#define C_YB 1183
#define C_YSCALE 14070  // 219/255 in Q14
#define C_U 7756
#define C_V 9139

static inline uint8_t clamp8(int32_t v) {
    return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

void x11cap_bgra_to_i420(const uint8_t *bgra, int stride, uint8_t *y, uint8_t *u,
                         uint8_t *v, int width, int height) {
    if (!bgra || !y || !u || !v || width <= 0 || height <= 0) return;
    const int cw = width / 2;

    for (int row = 0; row < height; row++) {
        const uint8_t *src = bgra + (size_t)row * (size_t)stride;
        uint8_t *ydst = y + (size_t)row * (size_t)width;
        for (int col = 0; col < width; col++) {
            const uint8_t *p = src + (size_t)col * 4;
            int32_t yf = (C_YR * p[2] + C_YG * p[1] + C_YB * p[0] + FXR) >> FX;
            ydst[col] = clamp8(16 + ((C_YSCALE * yf + FXR) >> FX));
        }
    }

    // Chroma from the 2×2 block average rather than a point sample: cheap, and
    // it avoids the shimmer point-sampling gives on text and thin lines, which
    // is most of what a shared screen contains.
    for (int row = 0; row + 1 < height; row += 2) {
        const uint8_t *r0 = bgra + (size_t)row * (size_t)stride;
        const uint8_t *r1 = r0 + stride;
        uint8_t *udst = u + (size_t)(row / 2) * (size_t)cw;
        uint8_t *vdst = v + (size_t)(row / 2) * (size_t)cw;
        for (int col = 0; col + 1 < width; col += 2) {
            const uint8_t *a = r0 + (size_t)col * 4;
            const uint8_t *b = a + 4;
            const uint8_t *c = r1 + (size_t)col * 4;
            const uint8_t *d = c + 4;
            int32_t bl = (a[0] + b[0] + c[0] + d[0] + 2) >> 2;
            int32_t gr = (a[1] + b[1] + c[1] + d[1] + 2) >> 2;
            int32_t re = (a[2] + b[2] + c[2] + d[2] + 2) >> 2;
            int32_t yf = (C_YR * re + C_YG * gr + C_YB * bl + FXR) >> FX;
            udst[col / 2] = clamp8(128 + ((C_U * (bl - yf) + FXR) >> FX));
            vdst[col / 2] = clamp8(128 + ((C_V * (re - yf) + FXR) >> FX));
        }
    }
}

int x11cap_grab_i420(x11cap_t *c, uint8_t *y, uint8_t *u, uint8_t *v,
                     int out_width, int out_height) {
    if (!c || !y || !u || !v) return -1;
    if (out_width <= 0 || out_height <= 0) return -1;
    if ((out_width & 1) || (out_height & 1)) return -1;
    if (out_width > c->width || out_height > c->height) return -1;

    const uint8_t *pixels = NULL;
    int stride = c->width * 4;

    if (c->use_shm) {
        xcb_shm_get_image_reply_t *img = xcb_shm_get_image_reply(
            c->conn,
            xcb_shm_get_image(c->conn, c->root, 0, 0, (uint16_t)c->width,
                              (uint16_t)c->height, ~0, XCB_IMAGE_FORMAT_Z_PIXMAP,
                              c->seg, 0),
            NULL);
        if (!img) return -2;
        free(img);
        pixels = c->shmaddr;
    } else {
        xcb_get_image_reply_t *img = xcb_get_image_reply(
            c->conn,
            xcb_get_image(c->conn, XCB_IMAGE_FORMAT_Z_PIXMAP, c->root, 0, 0,
                          (uint16_t)c->width, (uint16_t)c->height, ~0),
            NULL);
        if (!img) return -2;
        int len = xcb_get_image_data_length(img);
        if (len < stride * c->height) {
            free(img);
            return -2;
        }
        memcpy(c->fallback, xcb_get_image_data(img), (size_t)len);
        free(img);
        pixels = c->fallback;
    }

    x11cap_bgra_to_i420(pixels, stride, y, u, v, out_width, out_height);
    return 0;
}
