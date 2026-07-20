// sdl2.pc's Cflags point -I *into* the SDL2/ header dir
// (-I<prefix>/include/SDL2), so upstream code conventionally includes <SDL.h>.
// We spell the subdir explicitly (<SDL2/SDL.h>) so the header resolves the same
// way on Linux (/usr/include is a default clang search path) and via Homebrew's
// SDL2, and stays unambiguous read out of context.
#include <SDL2/SDL.h>

// Several SDL constants SDLKit needs are C *macros* (SDL_INIT_VIDEO,
// SDL_WINDOWPOS_UNDEFINED, SDL_PIXELFORMAT_IYUV) or C *enumerators* whose Swift
// import shape (struct vs. enum, raw-value width) varies by toolchain. Rather
// than depend on that, expose each as a plain, non-variadic static-inline shim
// returning a fixed-width integer — and read the tagged SDL_Event union through
// a shim too, so Swift never touches the union fields directly.

// SDL_INIT_VIDEO is a macro (0x00000020u).
static inline Uint32 sdlkit_init_video(void) { return SDL_INIT_VIDEO; }

// SDL_WINDOWPOS_UNDEFINED is a macro (0x1FFF0000u | 0).
static inline int sdlkit_windowpos_undefined(void) { return (int)SDL_WINDOWPOS_UNDEFINED; }

// SDL_PIXELFORMAT_IYUV — planar Y/U/V 4:2:0 (a.k.a. I420), the layout the
// FFmpeg decoder emits. The renderer does YUV→RGB on upload/copy.
static inline Uint32 sdlkit_pixelformat_iyuv(void) { return SDL_PIXELFORMAT_IYUV; }

// SDL_TEXTUREACCESS_STREAMING — a texture we re-upload each frame.
static inline int sdlkit_textureaccess_streaming(void) { return SDL_TEXTUREACCESS_STREAMING; }

// SDL_RENDERER_SOFTWARE — force SDL's CPU (XShm/XImage) renderer instead of the
// accelerated OpenGL one. `SDL_CreateRenderer(win, -1, 0)` otherwise picks the
// `opengl` driver, which dlopens libGL and creates a GLX context — fatal on an
// X server with no usable GLX FBConfig (e.g. X11 forwarded to XQuartz), where
// the Xlib error aborts the whole process before any fallback. The software
// renderer needs no GL and still does YUV→RGB on upload/copy.
static inline Uint32 sdlkit_renderer_software(void) { return SDL_RENDERER_SOFTWARE; }

// True when a pumped event means "the user wants the window closed" — either a
// top-level SDL_QUIT or a per-window close (SDL_WINDOWEVENT_CLOSE). Reading the
// SDL_Event union here keeps its variant access out of Swift.
static inline int sdlkit_event_should_close(const SDL_Event *event) {
    if (event == NULL) { return 0; }
    if (event->type == SDL_QUIT) { return 1; }
    if (event->type == SDL_WINDOWEVENT && event->window.event == SDL_WINDOWEVENT_CLOSE) { return 1; }
    return 0;
}
