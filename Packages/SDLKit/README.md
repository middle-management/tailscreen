# SDLKit

A thin, portable Swift wrapper over the system **SDL2**, for the
Linux/Windows viewer's video output — the counterpart to the macOS app's
Metal renderer.

## Why a local package, not a SwiftPM dependency

Tailscreen's viewer needs to put decoded frames on screen without pulling in
a heavy, platform-specific windowing stack. The FFmpeg decoder (see
`Packages/FFmpegKit`, when present) emits **8-bit planar YUV 4:2:0**, and
SDL2's IYUV streaming texture does the YUV→RGB conversion in the renderer
(on the GPU where one is available) — exactly the cheap, portable render
path a non-macOS viewer wants. So SDLKit wraps the plain C library the same
way `TailscaleKit` wraps libtailscale and `OpusKit` wraps libopus: a SwiftPM
`systemLibrary` target (`CSDL2`) plus a Foundation-only Swift wrapper
(`SDLKit`). The same source builds on Linux, macOS, and Windows against a
system SDL2.

## Prerequisite: SDL2

- **Linux:** `apt install libsdl2-dev`
- **macOS:** `brew install sdl2`
- **Windows:** `vcpkg install sdl2`

SwiftPM finds it via pkg-config (`sdl2.pc`); the `systemLibrary` target
declares `.apt(["libsdl2-dev"])` / `.brew(["sdl2"])` providers.

## API

Namespaced under `SDL` (so it doesn't collide with SDL's own `SDL_*` C
symbols):

```swift
import SDLKit

let window = try SDL.VideoWindow(title: "Tailscreen", width: 1280, height: 720)

// Per decoded frame — packed planes, Y pitch = width, U/V pitch = (width+1)/2:
try window.present(width: w, height: h, yPlane: y, uPlane: u, vPlane: v)

if window.pollShouldClose() { /* user closed the window */ }
```

`SDL.VideoWindow` owns the window, renderer, and a streaming
`SDL_PIXELFORMAT_IYUV` texture; `present` recreates the texture when the
frame size changes (a mid-stream resolution change) and uploads via
`SDL_UpdateYUVTexture`. SDL errors surface as a thrown `SDL.Error` carrying
`SDL_GetError()`. Not `Sendable` — like the Metal renderer it mirrors, one
instance is owned and driven from a single thread.

## Build & test

```bash
SDL_VIDEODRIVER=dummy swift test --package-path Packages/SDLKit   # needs SDL2
```

CI's `linux-sdl` job runs exactly this. The tests run headless against SDL's
**dummy** video driver (no display server), which falls back to SDL's
software renderer — that still performs real YUV texture uploads, so the
smoke test genuinely exercises window + renderer + texture-upload + present
(create, present a solid frame, present again at a different size to force
texture recreation, odd-dimension chroma rounding, and undersized-plane
rejection).

## Status

Standalone and additive — nothing in the repo depends on SDLKit yet. It's
the portable **Render** foundation for the Linux/Windows viewer
(`docs/porting-plan.md`); wiring it behind the FFmpeg decode path into a
running viewer is later work.
