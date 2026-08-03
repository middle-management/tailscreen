#include "ts_gtk_overlay.h"

#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <cairo.h>
#include <stdlib.h>
#include <string.h>

// See ts_gtk_overlay.h for what this is and why the pixel format needs no
// conversion. This file is the window: creation, click-through, placement,
// and getting bytes from a network thread onto the GTK main thread.

typedef struct {
    GtkWidget *window;
    GtkWidget *area;
    // Guards `pixels`/`width`/`height`, which the network thread writes and
    // the GTK main thread reads inside the draw handler.
    GMutex lock;
    unsigned char *pixels;  // premultiplied BGRA, tightly packed
    int width;
    int height;
    // Root-window placement, reapplied on map (see place()).
    int x;
    int y;
    // Set once the caller has asked for the window to be destroyed, so a
    // redraw already queued on the main loop becomes a no-op rather than
    // touching a freed handle.
    gboolean dead;
    // Sharer-drawing mode: pointer events land here instead of passing
    // through. See ts_gtk_overlay_set_interactive.
    gboolean interactive;
    void *cb_ctx;
    void (*on_pointer)(void *ctx, int32_t phase, double x, double y);
    void (*on_escape)(void *ctx);
    // Event controllers, added once at create time and simply ignored while
    // disarmed. Adding and removing them per arm would be more state to get
    // wrong for no gain: with an empty input region they never fire anyway.
    GtkGesture *drag;
    GtkEventController *keys;
    // Where the current drag started, in widget space. GtkGestureDrag's
    // update/end carry offsets, not positions.
    double drag_x;
    double drag_y;
} TSOverlay;

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

static void draw(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer user) {
    (void)area; (void)w; (void)h;
    TSOverlay *o = (TSOverlay *)user;

    // SOURCE, not the default OVER: the drawing area's backing store is not
    // guaranteed to start transparent, and compositing over stale content
    // would leave the previous frame's strokes behind. Painting the buffer as
    // the source replaces the pixels outright, alpha included, which is what
    // "here is the whole overlay right now" means.
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);

    g_mutex_lock(&o->lock);
    if (!o->pixels || o->width <= 0 || o->height <= 0) {
        g_mutex_unlock(&o->lock);
        cairo_set_source_rgba(cr, 0, 0, 0, 0);
        cairo_paint(cr);
        return;
    }
    cairo_surface_t *surface = cairo_image_surface_create_for_data(
        o->pixels, CAIRO_FORMAT_ARGB32, o->width, o->height,
        o->width * 4);
    if (cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS) {
        cairo_set_source_surface(cr, surface, 0, 0);
        cairo_paint(cr);
    }
    cairo_surface_destroy(surface);
    g_mutex_unlock(&o->lock);
}

// ---------------------------------------------------------------------------
// X11 window shaping
// ---------------------------------------------------------------------------

// Make the window override-redirect and put it exactly where we were asked to.
//
// GTK4 removed `gtk_window_move` and has no keep-above, both on the reasoning
// that a window manager owns placement and stacking. For an overlay that must
// sit precisely over the captured region and above everything else, that
// reasoning does not apply — so we opt out of the window manager entirely.
// Override-redirect is the X11 primitive for exactly this: no decoration, no
// placement policy, no focus stealing, and it is what X11 overlays have always
// used. It also means the overlay behaves identically under a full desktop and
// under a bare Xvfb with no window manager at all, which is what makes the
// self-test possible.
//
// Must run before the surface is mapped: X reads override_redirect at map
// time. GTK realizes the surface before showing it, so the "realize" handler
// is the window.
static void make_override_redirect(GtkWidget *widget, gpointer user) {
    TSOverlay *o = (TSOverlay *)user;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    if (!surface || !GDK_IS_X11_SURFACE(surface)) return;

    Display *dpy = GDK_SURFACE_XDISPLAY(surface);
    Window xid = GDK_SURFACE_XID(surface);
    XSetWindowAttributes attrs;
    attrs.override_redirect = True;
    XChangeWindowAttributes(dpy, xid, CWOverrideRedirect, &attrs);
    XMoveResizeWindow(dpy, xid, o->x, o->y,
                      (unsigned)(o->width > 0 ? o->width : 1),
                      (unsigned)(o->height > 0 ? o->height : 1));
    XFlush(dpy);
}

// Reassert position and stacking every time the window is shown.
//
// Both halves are needed. GTK sizes and places the surface itself as part of
// mapping, which can undo the move above; and an override-redirect window is
// only on top by virtue of where it sits in the stacking order at map time, so
// anything mapped later covers it until we raise again.
static void place(TSOverlay *o) {
    if (!o->window) return;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(o->window));
    if (!surface || !GDK_IS_X11_SURFACE(surface)) return;
    Display *dpy = GDK_SURFACE_XDISPLAY(surface);
    Window xid = GDK_SURFACE_XID(surface);
    XMoveResizeWindow(dpy, xid, o->x, o->y,
                      (unsigned)(o->width > 0 ? o->width : 1),
                      (unsigned)(o->height > 0 ? o->height : 1));
    XRaiseWindow(dpy, xid);
    XFlush(dpy);
}

// Click-through: an empty input region means every pointer event lands on
// whatever is underneath, so the sharer keeps using their machine normally
// with viewers' strokes floating over it.
//
// This is the GTK4-sanctioned route and needs no XShape extension — GDK
// translates it to an XFixes input shape. Applied on realize, alongside the
// override-redirect change, because both need the surface and neither wants
// the window mapped yet.
static void make_click_through(GtkWidget *widget, gpointer user) {
    (void)user;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    if (!surface) return;
    cairo_region_t *empty = cairo_region_create();
    gdk_surface_set_input_region(surface, empty);
    cairo_region_destroy(empty);
}

// The inverse: an input region covering the whole surface, so the overlay
// receives the pointer events the sharer makes over it.
static void make_interactive(GtkWidget *widget, int width, int height) {
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    if (!surface) return;
    cairo_rectangle_int_t all = {0, 0, width, height};
    cairo_region_t *full = cairo_region_create_rectangle(&all);
    gdk_surface_set_input_region(surface, full);
    cairo_region_destroy(full);
}

static void on_realize(GtkWidget *widget, gpointer user) {
    make_click_through(widget, user);
    make_override_redirect(widget, user);
}

// ---------------------------------------------------------------------------
// Sharer drawing
// ---------------------------------------------------------------------------

// Normalize a widget-space point to [0,1] over the overlay, which is exactly
// the capture region — so the result is already in `Annotation`'s space.
static void emit_pointer(TSOverlay *o, int32_t phase, double x, double y) {
    if (!o->on_pointer || o->width <= 0 || o->height <= 0) return;
    double nx = x / (double)o->width;
    double ny = y / (double)o->height;
    if (nx < 0) nx = 0; else if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; else if (ny > 1) ny = 1;
    o->on_pointer(o->cb_ctx, phase, nx, ny);
}

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer user) {
    (void)g;
    TSOverlay *o = (TSOverlay *)user;
    if (!o->interactive) return;
    o->drag_x = x;
    o->drag_y = y;
    emit_pointer(o, 0, x, y);
}

// GtkGestureDrag reports OFFSETS from the start, not absolute positions.
// Adding them back is the whole reason the start point is kept — a stroke
// drawn from the offsets alone lands in the top-left corner every time.
static void on_drag_update(GtkGestureDrag *g, double dx, double dy, gpointer user) {
    (void)g;
    TSOverlay *o = (TSOverlay *)user;
    if (!o->interactive) return;
    emit_pointer(o, 1, o->drag_x + dx, o->drag_y + dy);
}

static void on_drag_end(GtkGestureDrag *g, double dx, double dy, gpointer user) {
    (void)g;
    TSOverlay *o = (TSOverlay *)user;
    if (!o->interactive) return;
    emit_pointer(o, 2, o->drag_x + dx, o->drag_y + dy);
}

static gboolean on_key(GtkEventControllerKey *c, guint keyval, guint code,
                       GdkModifierType state, gpointer user) {
    (void)c; (void)code; (void)state;
    TSOverlay *o = (TSOverlay *)user;
    if (!o->interactive || keyval != GDK_KEY_Escape) return FALSE;
    if (o->on_escape) o->on_escape(o->cb_ctx);
    return TRUE;
}

void ts_gtk_overlay_set_input_callbacks(
    void *handle, void *ctx,
    void (*on_pointer)(void *ctx, int32_t phase, double x, double y),
    void (*on_escape)(void *ctx)) {
    TSOverlay *o = (TSOverlay *)handle;
    if (!o) return;
    o->cb_ctx = ctx;
    o->on_pointer = on_pointer;
    o->on_escape = on_escape;
}

int32_t ts_gtk_overlay_set_interactive(void *handle, int32_t on) {
    TSOverlay *o = (TSOverlay *)handle;
    if (!o || o->dead || !o->window) return 0;

    if (!on) {
        o->interactive = FALSE;
        make_click_through(o->window, NULL);
        GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(o->window));
        if (surface && GDK_IS_X11_SURFACE(surface)) {
            // Hand the keyboard back. Without this the desktop underneath
            // stays unable to type after a drawing session — the same class of
            // bug as a stuck pointer grab, and just as baffling.
            Display *dpy = GDK_SURFACE_XDISPLAY(surface);
            XSetInputFocus(dpy, PointerRoot, RevertToPointerRoot, CurrentTime);
            XFlush(dpy);
        }
        return 1;
    }

    // Must be mapped before it can be focused or receive pointer events.
    gtk_widget_set_visible(o->window, TRUE);
    place(o);
    make_interactive(o->window, o->width > 0 ? o->width : 1,
                     o->height > 0 ? o->height : 1);

    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(o->window));
    if (!surface || !GDK_IS_X11_SURFACE(surface)) {
        make_click_through(o->window, NULL);
        return 0;
    }
    // The window manager never focuses an override-redirect window, so this is
    // the only way Escape reaches us. Checked rather than assumed: if the
    // server refuses, we disarm and report failure, because the alternative is
    // a fullscreen window the sharer cannot dismiss.
    Display *dpy = GDK_SURFACE_XDISPLAY(surface);
    Window xid = GDK_SURFACE_XID(surface);
    XSetInputFocus(dpy, xid, RevertToPointerRoot, CurrentTime);
    XSync(dpy, False);

    Window focused = None;
    int revert = 0;
    XGetInputFocus(dpy, &focused, &revert);
    if (focused != xid) {
        o->interactive = FALSE;
        make_click_through(o->window, NULL);
        XFlush(dpy);
        return 0;
    }

    o->interactive = TRUE;
    gtk_widget_grab_focus(o->area);
    return 1;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

int32_t ts_gtk_overlay_supported(void) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return 0;
    // The compositing check, and the reason this function exists. See the
    // header: uncomposited X11 has no per-pixel alpha, so the overlay would be
    // an opaque black rectangle rather than floating strokes.
    return gdk_display_is_composited(display) ? 1 : 0;
}

void *ts_gtk_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) return NULL;

    TSOverlay *o = (TSOverlay *)calloc(1, sizeof(TSOverlay));
    if (!o) return NULL;
    g_mutex_init(&o->lock);
    o->x = x;
    o->y = y;
    o->width = width;
    o->height = height;

    o->window = gtk_window_new();
    gtk_window_set_decorated(GTK_WINDOW(o->window), FALSE);
    gtk_window_set_resizable(GTK_WINDOW(o->window), FALSE);
    gtk_window_set_default_size(GTK_WINDOW(o->window), width, height);
    // The window must not paint its own background, or it would cover the
    // screen in the theme's window colour before we draw a single stroke.
    // GTK4 has no "transparent window" flag; a CSS class carrying
    // `background: transparent` is the supported way to say it.
    gtk_widget_add_css_class(o->window, "ts-annotation-overlay");

    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(
        css, ".ts-annotation-overlay { background: transparent; }", -1);
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(css),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);

    o->area = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(o->area), width);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(o->area), height);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(o->area), draw, o, NULL);
    gtk_window_set_child(GTK_WINDOW(o->window), o->area);

    // Focusable so Escape can reach us once armed; a drawing area is not a
    // focus target by default and a key controller on an unfocusable widget
    // never fires.
    gtk_widget_set_focusable(o->area, TRUE);

    o->drag = gtk_gesture_drag_new();
    g_signal_connect(o->drag, "drag-begin", G_CALLBACK(on_drag_begin), o);
    g_signal_connect(o->drag, "drag-update", G_CALLBACK(on_drag_update), o);
    g_signal_connect(o->drag, "drag-end", G_CALLBACK(on_drag_end), o);
    gtk_widget_add_controller(o->area, GTK_EVENT_CONTROLLER(o->drag));

    o->keys = gtk_event_controller_key_new();
    g_signal_connect(o->keys, "key-pressed", G_CALLBACK(on_key), o);
    gtk_widget_add_controller(o->area, o->keys);

    g_signal_connect(o->window, "realize", G_CALLBACK(on_realize), o);
    return o;
}

// Runs on the GTK main thread, posted by ts_gtk_overlay_update.
static gboolean apply_update(gpointer user) {
    TSOverlay *o = (TSOverlay *)user;
    if (o->dead || !o->window) return G_SOURCE_REMOVE;
    gtk_widget_set_visible(o->window, TRUE);
    place(o);
    gtk_widget_queue_draw(o->area);
    return G_SOURCE_REMOVE;
}

static gboolean apply_hide(gpointer user) {
    TSOverlay *o = (TSOverlay *)user;
    if (o->dead || !o->window) return G_SOURCE_REMOVE;
    gtk_widget_set_visible(o->window, FALSE);
    return G_SOURCE_REMOVE;
}

void ts_gtk_overlay_update(void *handle, const uint8_t *bgra, int32_t stride,
                           int32_t width, int32_t height) {
    TSOverlay *o = (TSOverlay *)handle;
    if (!o || !bgra || width <= 0 || height <= 0) return;
    if (stride < width * 4) return;

    // Repack to tightly-packed while copying: cairo wants a stride it agrees
    // with, and the caller's may be padded. One pass, and it has to be a copy
    // regardless — the caller reuses its buffer for the next frame.
    size_t bytes = (size_t)width * (size_t)height * 4;
    unsigned char *copy = (unsigned char *)malloc(bytes);
    if (!copy) return;
    for (int row = 0; row < height; row++) {
        memcpy(copy + (size_t)row * (size_t)width * 4,
               bgra + (size_t)row * (size_t)stride, (size_t)width * 4);
    }

    g_mutex_lock(&o->lock);
    free(o->pixels);
    o->pixels = copy;
    o->width = width;
    o->height = height;
    g_mutex_unlock(&o->lock);

    g_idle_add(apply_update, o);
}

void ts_gtk_overlay_hide(void *handle) {
    TSOverlay *o = (TSOverlay *)handle;
    if (!o) return;
    g_idle_add(apply_hide, o);
}

static gboolean apply_destroy(gpointer user) {
    TSOverlay *o = (TSOverlay *)user;
    if (o->window) {
        gtk_window_destroy(GTK_WINDOW(o->window));
        o->window = NULL;
        o->area = NULL;
    }
    return G_SOURCE_REMOVE;
}

void ts_gtk_overlay_destroy(void *handle) {
    TSOverlay *o = (TSOverlay *)handle;
    if (!o) return;
    // `dead` is latched first, so an `apply_update` already sitting on the
    // main loop returns instead of drawing into a window that is about to go.
    o->dead = TRUE;
    g_mutex_lock(&o->lock);
    free(o->pixels);
    o->pixels = NULL;
    g_mutex_unlock(&o->lock);
    // The window itself is destroyed ON THE MAIN THREAD, like every other GTK
    // call here. That is not defensive tidiness: the owner is held by the
    // server's annotation callback, so the last release can genuinely land on
    // a network thread, and destroying a GTK window from one is a crash rather
    // than a warning.
    g_idle_add(apply_destroy, o);
    // The handle is deliberately NOT freed: queued idle callbacks still hold
    // this pointer and GLib offers no way to cancel by user data. One leaked
    // struct per share is the cheap side of that trade.
}
