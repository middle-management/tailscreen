#include "cgtkvideo.h"
#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>

static int inited = 0;
static GLuint prog, vao, texY, texU, texV;

static const char *VS =
"#version 300 es\n"
"out vec2 uv;\n"
"void main(){\n"
"  vec2 p = vec2((gl_VertexID==1||gl_VertexID==3)?1.0:-1.0,\n"
"                (gl_VertexID==2||gl_VertexID==3)?1.0:-1.0);\n"
"  uv = vec2((p.x+1.0)*0.5, (1.0-p.y)*0.5);\n"
"  gl_Position = vec4(p,0.0,1.0);\n"
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
    inited = 1;
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

    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
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
    int ok = white && black && red && blue;
    fprintf(stderr, "CGTKVIDEO_SELFTEST result=%s\n", ok ? "PASS" : "FAIL");
    fflush(stderr);
    return ok ? 1 : 0;
}
