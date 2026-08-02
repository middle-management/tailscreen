#include "ts_xtest.h"

#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <stdlib.h>

// See ts_xtest.h for what this is and why it exists at all. Everything with a
// decision in it is in Swift; this owns the Display and the keymap lookup.

typedef struct {
    Display *dpy;
} TSXTest;

void *ts_xtest_open(const char *display_name) {
    Display *dpy = XOpenDisplay(display_name);
    if (!dpy) return NULL;

    // XTEST is an OPTIONAL extension. Without this check every XTestFake* call
    // below is a no-op that reports nothing, and the sharer would grant remote
    // control to a viewer whose every click vanishes — the exact class of
    // silent failure the capability bits exist to prevent. The four out
    // parameters are required by the API and unused.
    int event_base = 0, error_base = 0, major = 0, minor = 0;
    if (!XTestQueryExtension(dpy, &event_base, &error_base, &major, &minor)) {
        XCloseDisplay(dpy);
        return NULL;
    }

    TSXTest *x = (TSXTest *)calloc(1, sizeof(TSXTest));
    if (!x) {
        XCloseDisplay(dpy);
        return NULL;
    }
    x->dpy = dpy;
    return x;
}

void ts_xtest_close(void *handle) {
    TSXTest *x = (TSXTest *)handle;
    if (!x) return;
    if (x->dpy) XCloseDisplay(x->dpy);
    free(x);
}

void ts_xtest_motion(void *handle, int32_t x, int32_t y) {
    TSXTest *t = (TSXTest *)handle;
    if (!t) return;
    // Screen -1 means "the screen the pointer is currently on", which is what
    // a single-root multi-monitor setup (Xinerama/RandR — i.e. every modern
    // one) wants: there is one root spanning every monitor, and the pointer
    // coordinates are already in its space.
    XTestFakeMotionEvent(t->dpy, -1, x, y, 0);
}

void ts_xtest_button(void *handle, int32_t button, int32_t down) {
    TSXTest *t = (TSXTest *)handle;
    if (!t || button <= 0) return;
    XTestFakeButtonEvent(t->dpy, (unsigned int)button, down ? True : False, 0);
}

int32_t ts_xtest_key(void *handle, uint32_t keysym, int32_t down) {
    TSXTest *t = (TSXTest *)handle;
    if (!t) return 0;
    KeyCode code = XKeysymToKeycode(t->dpy, (KeySym)keysym);
    // 0 is "no key on this keymap produces that symbol" — routine, not an
    // error, and reported so the caller drops the keystroke rather than
    // injecting keycode 0 (which is not a key and would be discarded by the
    // server anyway, but silently).
    if (code == 0) return 0;
    XTestFakeKeyEvent(t->dpy, code, down ? True : False, 0);
    return 1;
}

void ts_xtest_root_size(void *handle, int32_t *out_width, int32_t *out_height) {
    TSXTest *t = (TSXTest *)handle;
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!t) return;
    int screen = DefaultScreen(t->dpy);
    if (out_width) *out_width = (int32_t)DisplayWidth(t->dpy, screen);
    if (out_height) *out_height = (int32_t)DisplayHeight(t->dpy, screen);
}

void ts_xtest_flush(void *handle) {
    TSXTest *t = (TSXTest *)handle;
    if (!t) return;
    XFlush(t->dpy);
}

void ts_xtest_pointer_position(void *handle, int32_t *out_x, int32_t *out_y) {
    TSXTest *t = (TSXTest *)handle;
    if (out_x) *out_x = -1;
    if (out_y) *out_y = -1;
    if (!t) return;
    Window root = DefaultRootWindow(t->dpy);
    Window root_return, child_return;
    int root_x = 0, root_y = 0, win_x = 0, win_y = 0;
    unsigned int mask = 0;
    if (!XQueryPointer(t->dpy, root, &root_return, &child_return, &root_x, &root_y, &win_x,
                       &win_y, &mask)) {
        return;
    }
    if (out_x) *out_x = (int32_t)root_x;
    if (out_y) *out_y = (int32_t)root_y;
}

const char *ts_xtest_keysym_name(uint32_t keysym) {
    // Needs no display: keysym names are a protocol-level table compiled into
    // Xlib, which is what lets the probe check every row of X11KeyCodeMapping
    // without an X server.
    return XKeysymToString((KeySym)keysym);
}
