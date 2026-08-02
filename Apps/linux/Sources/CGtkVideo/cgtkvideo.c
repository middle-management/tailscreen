#include "cgtkvideo.h"
#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>

static int inited = 0;
static GLuint prog, vao, texY, texU, texV;
static GLint uXformLoc = -1;
// View state (zoom ≥ 1, pan in NDC), settable from Swift via cgtkvideo_set_view.
static float gZoom = 1.0f, gPanX = 0.0f, gPanY = 0.0f;
// The last aspect-fit × zoom scale computed by cgtkvideo_draw_yuv, reused by the
// annotation renderer so strokes track the video content (letterbox + zoom/pan).
static float gLastSx = 1.0f, gLastSy = 1.0f;

// --- Annotation line renderer -----------------------------------------------
static int annInited = 0;
static GLuint annProg, annVao, annVbo;
static GLint annPosLoc = -1, annColorLoc = -1;

static const char *VS =
"#version 300 es\n"
"uniform vec4 uXform;\n"  // xy = scale (aspect-fit × zoom), zw = pan offset (NDC)
"out vec2 uv;\n"
"void main(){\n"
"  vec2 p = vec2((gl_VertexID==1||gl_VertexID==3)?1.0:-1.0,\n"
"                (gl_VertexID==2||gl_VertexID==3)?1.0:-1.0);\n"
"  uv = vec2((p.x+1.0)*0.5, (1.0-p.y)*0.5);\n"  // texcoord from the base quad
"  gl_Position = vec4(p*uXform.xy + uXform.zw, 0.0, 1.0);\n"  // letterbox/zoom/pan
"}\n";

static const char *FS =
"#version 300 es\n"
"precision highp float;\n"
"in vec2 uv;\n"
"uniform sampler2D texY, texU, texV;\n"
"out vec4 frag;\n"
"void main(){\n"
"  float y = (texture(texY,uv).r - 16.0/255.0) * (255.0/219.0);\n"
"  float u = (texture(texU,uv).r - 0.5) * (255.0/224.0);\n"
"  float v = (texture(texV,uv).r - 0.5) * (255.0/224.0);\n"
"  float r = y + 1.5748*v;\n"
"  float g = y - 0.1873*u - 0.4681*v;\n"
"  float b = y + 1.8556*u;\n"
"  frag = vec4(clamp(vec3(r,g,b),0.0,1.0),1.0);\n"
"}\n";

static GLuint compile(GLenum t, const char *src) {
    GLuint s = glCreateShader(t);
    glShaderSource(s, 1, &src, 0);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512]; glGetShaderInfoLog(s, 512, 0, log); fprintf(stderr, "CGTKVIDEO shader compile error: %s\n", log); }
    return s;
}

static GLuint mktex(void) {
    GLuint t;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return t;
}

static void init(void) {
    GLuint vs = compile(GL_VERTEX_SHADER, VS), fs = compile(GL_FRAGMENT_SHADER, FS);
    prog = glCreateProgram();
    glAttachShader(prog, vs); glAttachShader(prog, fs); glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) { char log[512]; glGetProgramInfoLog(prog, 512, 0, log); fprintf(stderr, "CGTKVIDEO program link error: %s\n", log); }
    glDeleteShader(vs); glDeleteShader(fs);
    glGenVertexArrays(1, &vao);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    texY = mktex(); texU = mktex(); texV = mktex();
    // Sampler→unit bindings are program state; set once (they persist).
    glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "texY"), 0);
    glUniform1i(glGetUniformLocation(prog, "texU"), 1);
    glUniform1i(glGetUniformLocation(prog, "texV"), 2);
    uXformLoc = glGetUniformLocation(prog, "uXform");
    inited = 1;
}

void cgtkvideo_set_view(float zoom, float pan_x, float pan_y) {
    gZoom = zoom;
    gPanX = pan_x;
    gPanY = pan_y;
}

static void upload(GLuint tex, int w, int h, const uint8_t *data) {
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, data);
}

void cgtkvideo_draw_yuv(int32_t width, int32_t height,
                        const uint8_t *y, const uint8_t *u, const uint8_t *v) {
    if (!inited) init();
    int cw = (width + 1) / 2, ch = (height + 1) / 2;  // ceil: match DecodedVideoFrame plane dims
    upload(texY, width, height, y);
    upload(texU, cw, ch, u);
    upload(texV, cw, ch, v);

    // Aspect-fit: scale the video quad to preserve its aspect inside the
    // viewport (black letterbox bars are the cleared background), then apply
    // zoom (≥1) and pan. Fitting to width when the frame is wider than the
    // viewport, else to height.
    GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);
    float sx = 1.0f, sy = 1.0f;
    if (vp[2] > 0 && vp[3] > 0 && width > 0 && height > 0) {
        float viewportAspect = (float)vp[2] / (float)vp[3];
        float frameAspect = (float)width / (float)height;
        if (frameAspect > viewportAspect) sy = viewportAspect / frameAspect;
        else sx = frameAspect / viewportAspect;
    }
    sx *= gZoom;
    sy *= gZoom;
    gLastSx = sx;
    gLastSy = sy;

    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glUniform4f(uXformLoc, sx, sy, gPanX, gPanY);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, texY);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, texU);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, texV);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void cgtkvideo_clear(void) {
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}

void cgtkvideo_reset(void) {
    // GL objects belonged to a context being torn down (freed with it); just
    // forget them so the next draw re-inits against the fresh context.
    inited = 0;
    annInited = 0;
}

// --- Annotation line renderer -----------------------------------------------
static const char *ANN_VS =
"#version 300 es\n"
"in vec2 aPos;\n"  // NDC position
"void main(){ gl_Position = vec4(aPos, 0.0, 1.0); }\n";

static const char *ANN_FS =
"#version 300 es\n"
"precision highp float;\n"
"uniform vec4 uColor;\n"
"out vec4 frag;\n"
"void main(){ frag = uColor; }\n";

static void ann_init(void) {
    GLuint vs = compile(GL_VERTEX_SHADER, ANN_VS), fs = compile(GL_FRAGMENT_SHADER, ANN_FS);
    annProg = glCreateProgram();
    glAttachShader(annProg, vs); glAttachShader(annProg, fs); glLinkProgram(annProg);
    glDeleteShader(vs); glDeleteShader(fs);
    annPosLoc = glGetAttribLocation(annProg, "aPos");
    annColorLoc = glGetUniformLocation(annProg, "uColor");
    glGenVertexArrays(1, &annVao);
    glGenBuffers(1, &annVbo);
    annInited = 1;
}

void cgtkvideo_draw_annotations(const float *norm_xy, const int *counts,
                                int n_strokes, const float *rgba,
                                const float *widths_px) {
    if (n_strokes <= 0 || !norm_xy || !counts || !rgba) return;
    if (!inited) return;  // no video drawn yet ⇒ no transform to map against
    if (!annInited) ann_init();

    glUseProgram(annProg);
    glBindVertexArray(annVao);
    glBindBuffer(GL_ARRAY_BUFFER, annVbo);
    glEnableVertexAttribArray((GLuint)annPosLoc);
    glVertexAttribPointer((GLuint)annPosLoc, 2, GL_FLOAT, GL_FALSE, 0, 0);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    int offset = 0;  // running point index into norm_xy
    for (int s = 0; s < n_strokes; s++) {
        int n = counts[s];
        if (n <= 0) continue;
        // Map each normalized (u,v), origin top-left, to NDC through the same
        // aspect-fit × zoom + pan transform the video quad uses:
        //   ndc = ((2u-1)*sx + panX, (1-2v)*sy + panY)
        float *ndc = (float *)malloc(sizeof(float) * 2 * (size_t)n);
        if (!ndc) break;
        for (int i = 0; i < n; i++) {
            float u = norm_xy[(offset + i) * 2 + 0];
            float v = norm_xy[(offset + i) * 2 + 1];
            ndc[i * 2 + 0] = (2.0f * u - 1.0f) * gLastSx + gPanX;
            ndc[i * 2 + 1] = (1.0f - 2.0f * v) * gLastSy + gPanY;
        }
        glBufferData(GL_ARRAY_BUFFER, sizeof(float) * 2 * (size_t)n, ndc, GL_STREAM_DRAW);
        glUniform4f(annColorLoc, rgba[s * 4 + 0], rgba[s * 4 + 1], rgba[s * 4 + 2], rgba[s * 4 + 3]);
        float w = widths_px ? widths_px[s] : 3.0f;
        if (w < 1.0f) w = 1.0f;
        glLineWidth(w);
        glDrawArrays(n == 1 ? GL_POINTS : GL_LINE_STRIP, 0, n);
        free(ndc);
        offset += n;
    }
    glDisableVertexAttribArray((GLuint)annPosLoc);
}

int32_t cgtkvideo_selftest_check(void) {
    // NOTE: reads the bound single-sample GLArea FBO. GtkGLArea does not enable
    // MSAA by default; if that ever changes, blit-resolve before reading.
    GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);
    int fw = vp[2], fh = vp[3];
    unsigned char px[4][4];
    for (int i = 0; i < 4; i++) {
        int x = fw * (2 * i + 1) / 8, py = fh / 2;
        glReadPixels(x, py, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px[i]);
        fprintf(stderr, "CGTKVIDEO_SELFTEST bar%d rgb=%d,%d,%d\n", i, px[i][0], px[i][1], px[i][2]);
    }
    int white = px[0][0] > 200 && px[0][1] > 200 && px[0][2] > 200;
    int black = px[1][0] < 60 && px[1][1] < 60 && px[1][2] < 60;
    int red = px[2][0] > 180 && px[2][0] > px[2][2] + 60;
    int blue = px[3][2] > 180 && px[3][2] > px[3][0] + 60;
    // Letterbox check: the 4:1 bars frame in a less-wide viewport is fit to
    // width, so the top edge must be a black letterbox bar (with a plain stretch
    // it would be the white bar). Proves aspect-fit is actually applied.
    unsigned char top[4] = {0};
    glReadPixels(fw / 2, fh - 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, top);
    int letterbox = top[0] < 60 && top[1] < 60 && top[2] < 60;
    fprintf(stderr, "CGTKVIDEO_SELFTEST letterbox_top rgb=%d,%d,%d\n", top[0], top[1], top[2]);
    int ok = white && black && red && blue && letterbox;
    fprintf(stderr, "CGTKVIDEO_SELFTEST result=%s\n", ok ? "PASS" : "FAIL");
    fflush(stderr);
    return ok ? 1 : 0;
}

// Forward-declare the gtk/glib entry points (resolved at final link against
// libgtk-4 / libglib-2.0, which the swift-cross-ui GtkBackend already links) so
// this target needs no gtk include path. GtkWidget* and GtkGLArea* share the
// same GObject address, so passing the area's widget pointer is valid.
typedef struct _GtkGLArea GtkGLArea;
typedef int gboolean;
typedef void *gpointer;
typedef gboolean (*GSourceFunc)(gpointer);
extern void gtk_gl_area_queue_render(GtkGLArea *area);
extern unsigned int g_idle_add(GSourceFunc function, gpointer data);

static gboolean cgtkvideo_render_idle(gpointer data) {
    gtk_gl_area_queue_render((GtkGLArea *)data);
    return 0;  // G_SOURCE_REMOVE — one-shot
}

void cgtkvideo_queue_render(void *gl_area_widget) {
    // Marshal onto the GTK main thread. g_idle_add is safe to call from ANY
    // thread; the idle source runs on whichever thread iterates the default main
    // context (the GTK main thread). So the caller (`present`) need not be on
    // the main thread — GTK is only ever touched here, deferred to its own
    // thread. (The frame data path is separately made safe by FrameStore's
    // lock + value-type copy.)
    if (gl_area_widget) g_idle_add(cgtkvideo_render_idle, gl_area_widget);
}

// Forward-declare the few widget accessors the input layer needs (resolved at
// final link against libgtk-4, as with the queue-render symbols above). A
// GtkWidget* is opaque here; passing the area's widget pointer through as void*
// is ABI-compatible (C ignores parameter types for symbol resolution).
extern int gtk_widget_get_width(void *widget);
extern int gtk_widget_get_height(void *widget);
extern void gtk_widget_set_focusable(void *widget, gboolean focusable);
extern void gtk_widget_grab_focus(void *widget);

void cgtkvideo_widget_size(void *widget, int32_t *out_w, int32_t *out_h) {
    if (out_w) *out_w = widget ? (int32_t)gtk_widget_get_width(widget) : 0;
    if (out_h) *out_h = widget ? (int32_t)gtk_widget_get_height(widget) : 0;
}

void cgtkvideo_widget_make_focusable(void *widget) {
    if (widget) gtk_widget_set_focusable(widget, 1);
}

void cgtkvideo_widget_grab_focus(void *widget) {
    if (widget) gtk_widget_grab_focus(widget);
}

// GtkRoot* gtk_widget_get_root(GtkWidget*) — the widget's toplevel (a GtkWindow
// for a normal window); GtkWindow implements GtkRoot, so the pointer is a valid
// GtkWindow*. gtk_window_set_default_size resizes it (GTK4 has no gtk_window_resize).
extern void *gtk_widget_get_root(void *widget);
extern void gtk_window_set_default_size(void *window, int width, int height);

void cgtkvideo_resize_toplevel(void *widget, int32_t w, int32_t h) {
    if (!widget || w <= 0 || h <= 0) return;
    void *root = gtk_widget_get_root(widget);
    if (root) gtk_window_set_default_size(root, (int)w, (int)h);
}

// --- Scroll controller shim --------------------------------------------------
//
// swift-cross-ui binds EventControllerMotion/Key/GestureClick but NOT
// EventControllerScroll, so the zoom/pan input can't be wired from Swift alone.
// Create a native GtkEventControllerScroll here and forward its deltas (plus the
// modifier state, read from the controller's current event) to a Swift callback.
// All symbols are forward-declared (void* opaque handles — C ignores parameter
// types for symbol resolution) so this GL-only target still pulls no gtk headers.
typedef unsigned long gulong;
typedef void (*GCallback)(void);
// GtkEventControllerScrollFlags: VERTICAL(1) | HORIZONTAL(1<<1) == BOTH_AXES(3).
#define CGTKVIDEO_SCROLL_BOTH_AXES 3u
extern void *gtk_event_controller_scroll_new(unsigned int flags);
extern void gtk_widget_add_controller(void *widget, void *controller);
extern void *gtk_event_controller_get_current_event(void *controller);
extern unsigned int gdk_event_get_modifier_state(void *event);
extern gulong g_signal_connect_data(void *instance, const char *detailed_signal,
                                     GCallback c_handler, void *data,
                                     void *destroy_data, int connect_flags);

typedef struct {
    cgtkvideo_scroll_cb cb;
    void *user;
} CgtkScrollCtx;

// GtkEventControllerScroll::scroll — return TRUE (1) to mark the event handled so
// it doesn't bubble to a scrollable ancestor. `self` is the controller; its
// current event carries the modifier state.
static int cgtkvideo_scroll_handler(void *self, double dx, double dy, void *data) {
    CgtkScrollCtx *ctx = (CgtkScrollCtx *)data;
    unsigned int mods = 0;
    void *ev = gtk_event_controller_get_current_event(self);
    if (ev) mods = gdk_event_get_modifier_state(ev);
    if (ctx && ctx->cb) ctx->cb(dx, dy, mods, ctx->user);
    return 1;  // GDK_EVENT_STOP
}

// GClosureNotify to free the heap context when the closure (and thus the
// controller/widget) is finalized.
static void cgtkvideo_scroll_ctx_free(void *data, void *closure) {
    (void)closure;
    free(data);
}

void cgtkvideo_attach_scroll(void *widget, cgtkvideo_scroll_cb cb, void *user) {
    if (!widget || !cb) return;
    CgtkScrollCtx *ctx = (CgtkScrollCtx *)malloc(sizeof(CgtkScrollCtx));
    if (!ctx) return;
    ctx->cb = cb;
    ctx->user = user;
    void *controller = gtk_event_controller_scroll_new(CGTKVIDEO_SCROLL_BOTH_AXES);
    g_signal_connect_data(controller, "scroll", (GCallback)cgtkvideo_scroll_handler,
                          ctx, (void *)cgtkvideo_scroll_ctx_free, 0);
    gtk_widget_add_controller(widget, controller);  // widget takes ownership
}
