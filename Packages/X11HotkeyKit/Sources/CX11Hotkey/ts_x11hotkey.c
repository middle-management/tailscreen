#include "ts_x11hotkey.h"

#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <stdlib.h>

// See ts_x11hotkey.h for what this is and why it exists at all.

typedef struct {
    Display *dpy;
    Window root;
    int detectable_autorepeat;
    // The keycode + masks currently grabbed, so ungrab can undo exactly what
    // grab installed. 8 is the size of X11HotkeyMapping.grabMasks; the cap is
    // asserted by refusing a larger request rather than silently truncating.
    unsigned int keycode;
    unsigned int masks[16];
    int mask_count;
} TSHotkey;

// Xlib's error handler is per-PROCESS, not per-display, and the app that links
// this also has GTK's own display connection. It is installed only around the
// grab and its XSync, both of which run on the host's main thread — the same
// thread GTK runs on — so there is no window in which another Xlib caller could
// have its error swallowed.
static int g_grab_failed = 0;
static int (*g_previous_handler)(Display *, XErrorEvent *) = NULL;

static int ts_grab_error_handler(Display *dpy, XErrorEvent *event) {
    (void)dpy;
    (void)event;
    g_grab_failed = 1;
    return 0;
}

void *ts_hotkey_open(const char *display_name) {
    Display *dpy = XOpenDisplay(display_name);
    if (!dpy) return NULL;

    TSHotkey *h = (TSHotkey *)calloc(1, sizeof(TSHotkey));
    if (!h) {
        XCloseDisplay(dpy);
        return NULL;
    }
    h->dpy = dpy;
    h->root = DefaultRootWindow(dpy);

    // Ask for detectable auto-repeat: a held key then repeats KeyPress with no
    // synthetic KeyRelease between, which is what makes the Swift latch able
    // to tell a repeat from a real second press.
    Bool supported = False;
    XkbSetDetectableAutoRepeat(dpy, True, &supported);
    h->detectable_autorepeat = supported ? 1 : 0;
    return h;
}

void ts_hotkey_close(void *handle) {
    TSHotkey *h = (TSHotkey *)handle;
    if (!h) return;
    ts_hotkey_ungrab(handle);
    if (h->dpy) XCloseDisplay(h->dpy);
    free(h);
}

int32_t ts_hotkey_detectable_autorepeat(void *handle) {
    TSHotkey *h = (TSHotkey *)handle;
    if (!h) return 0;
    return (int32_t)h->detectable_autorepeat;
}

int32_t ts_hotkey_grab(void *handle, uint32_t keysym, const uint32_t *masks, int32_t count) {
    TSHotkey *h = (TSHotkey *)handle;
    if (!h || !masks || count <= 0) return 0;
    if ((size_t)count > sizeof(h->masks) / sizeof(h->masks[0])) return 0;

    ts_hotkey_ungrab(handle);

    KeyCode keycode = XKeysymToKeycode(h->dpy, (KeySym)keysym);
    // 0 means no key on this keymap produces that symbol — routine (a layout
    // without the key), not an error, and reported so the host declines the
    // shortcut instead of advertising one that cannot fire.
    if (keycode == 0) return 0;

    g_grab_failed = 0;
    g_previous_handler = XSetErrorHandler(ts_grab_error_handler);

    for (int32_t i = 0; i < count; i++) {
        XGrabKey(h->dpy, keycode, (unsigned int)masks[i], h->root, True, GrabModeAsync,
                 GrabModeAsync);
        h->masks[i] = (unsigned int)masks[i];
    }
    h->keycode = (unsigned int)keycode;
    h->mask_count = (int)count;

    // XGrabKey queues; the BadAccess for a chord another client already owns
    // arrives later. XSync round-trips so the handler above has definitely run
    // by the time it returns — without this the function reports success for a
    // grab that was refused, which is precisely the silent failure the whole
    // capability-honesty rule exists to prevent.
    XSync(h->dpy, False);
    XSetErrorHandler(g_previous_handler);
    g_previous_handler = NULL;

    if (g_grab_failed) {
        ts_hotkey_ungrab(handle);
        return 0;
    }
    return 1;
}

void ts_hotkey_ungrab(void *handle) {
    TSHotkey *h = (TSHotkey *)handle;
    if (!h || h->mask_count == 0) return;
    for (int i = 0; i < h->mask_count; i++) {
        XUngrabKey(h->dpy, (int)h->keycode, h->masks[i], h->root);
    }
    h->mask_count = 0;
    h->keycode = 0;
    XSync(h->dpy, False);
}

int32_t ts_hotkey_poll(void *handle, int32_t *out_events, int32_t capacity) {
    TSHotkey *h = (TSHotkey *)handle;
    if (!h || !out_events || capacity <= 0) return -1;

    int32_t written = 0;
    // XPending flushes the output buffer and reports what has already arrived,
    // so this never blocks — the property that lets a UI tick call it.
    while (written < capacity && XPending(h->dpy) > 0) {
        XEvent event;
        XNextEvent(h->dpy, &event);
        if (event.type == KeyPress) {
            out_events[written++] = 1;
        } else if (event.type == KeyRelease) {
            out_events[written++] = 0;
        }
        // Anything else on this connection is not ours to act on: the display
        // is opened solely for the grab.
    }
    return written;
}
