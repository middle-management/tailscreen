import CSDL2
import Foundation

/// Thin Swift wrapper over SDL2 for Tailscreen's Linux/Windows viewer video
/// output — the portable counterpart to the macOS app's Metal renderer.
/// Foundation-only and cross-platform: the same source builds anywhere a
/// system SDL2 is present (apt `libsdl2-dev`, brew `sdl2`, vcpkg `sdl2`).
///
/// Namespaced under `SDL` so `SDL.VideoWindow` / `SDL.Error` don't collide with
/// SDL's own `SDL_*` C symbols.
public enum SDL {
    /// An SDL failure surfaced to Swift. `message` is `SDL_GetError()` captured
    /// at the point the wrapped call reported failure.
    public struct Error: Swift.Error, Equatable {
        public let message: String

        init() {
            // SDL_GetError never returns NULL — it's an empty string when unset.
            self.message = String(cString: SDL_GetError())
        }

        init(_ message: String) {
            self.message = message
        }
    }

    /// A window + renderer + streaming YUV texture that displays decoded video
    /// frames. Renders **8-bit planar YUV 4:2:0** (`SDL_PIXELFORMAT_IYUV`, the
    /// format the FFmpeg decoder emits): the SDL renderer does the YUV→RGB
    /// conversion on upload/copy, so the viewer hands over decoded planes and
    /// nothing else.
    ///
    /// Not `Sendable` — like the Metal renderer it mirrors, an instance is
    /// owned and driven from a single thread (SDL video/event calls must all
    /// run on the thread that initialised the subsystem).
    public final class VideoWindow {
        private let window: OpaquePointer
        private let renderer: OpaquePointer
        private var texture: OpaquePointer?
        /// The dimensions `texture` was created at; a `present` with different
        /// dimensions recreates it (a resolution change mid-stream).
        private var textureWidth: Int32 = 0
        private var textureHeight: Int32 = 0

        /// Create the window, renderer, and an initial streaming IYUV texture.
        ///
        /// - Parameters:
        ///   - title: window title bar text.
        ///   - width: initial window/texture width in pixels.
        ///   - height: initial window/texture height in pixels.
        ///   - softwareRenderer: force SDL's CPU renderer instead of the
        ///     accelerated OpenGL one. Defaults to `true` because the common
        ///     deployment (X11 forwarded to XQuartz over OrbStack) has no
        ///     usable GLX FBConfig, so `-1`/accelerated selection dlopens libGL
        ///     and fatally X-errors the process. Pass `false` on a native Linux
        ///     desktop with working GL to get GPU-accelerated scaling.
        /// - Throws: `SDL.Error` if any SDL object fails to initialise.
        public init(title: String, width: Int, height: Int, softwareRenderer: Bool = true) throws {
            guard SDL_Init(sdlkit_init_video()) == 0 else {
                throw Error()
            }

            let undefined = sdlkit_windowpos_undefined()
            guard let window = SDL_CreateWindow(
                title, undefined, undefined, Int32(width), Int32(height), 0
            ) else {
                let error = Error()
                SDL_Quit()
                throw error
            }
            self.window = window

            // -1 picks the first suitable driver. Left to itself that's the
            // `opengl` driver, which dlopens libGL and creates a GLX context —
            // fatal on an X server with no usable GLX FBConfig (X11 → XQuartz).
            // `SDL_RENDERER_SOFTWARE` forces the CPU renderer (no GL), which
            // still supports YUV texture upload + copy. Under the CI dummy video
            // driver either path resolves to software anyway.
            let rendererFlags: UInt32 = softwareRenderer ? sdlkit_renderer_software() : 0
            guard let renderer = SDL_CreateRenderer(window, -1, rendererFlags) else {
                let error = Error()
                SDL_DestroyWindow(window)
                SDL_Quit()
                throw error
            }
            self.renderer = renderer

            // Some remote X servers (XQuartz over OrbStack) don't map/expose the
            // window off SDL_CreateWindow alone — force it visible + raised.
            SDL_ShowWindow(window)
            SDL_RaiseWindow(window)

            // Warn loudly if SDL fell back to a non-displaying driver. When
            // `DISPLAY` is unset or unreachable (e.g. XQuartz's Mac-only launchd
            // socket path, invisible from inside a Linux guest), SDL silently
            // selects the `offscreen`/`dummy` driver and renders into memory —
            // frames "present" with no error but nothing ever appears. Say so
            // instead of leaving the user staring at a void.
            if let driverC = SDL_GetCurrentVideoDriver() {
                let driver = String(cString: driverC)
                if driver == "offscreen" || driver == "dummy" {
                    let msg = "warning: SDL video driver is '\(driver)' — the window will NOT be visible. "
                        + "Set DISPLAY to a reachable X server (e.g. DISPLAY=host.docker.internal:0 for "
                        + "XQuartz over OrbStack, or run under Xvfb).\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            }

            do {
                try createTexture(width: Int32(width), height: Int32(height))
            } catch {
                SDL_DestroyRenderer(renderer)
                SDL_DestroyWindow(window)
                SDL_Quit()
                throw error
            }
        }

        deinit {
            if let texture { SDL_DestroyTexture(texture) }
            SDL_DestroyRenderer(renderer)
            SDL_DestroyWindow(window)
            SDL_Quit()
        }

        /// Upload one decoded frame and present it. The three planes are packed
        /// (no per-row padding): Y is `width` bytes per row, U and V are each
        /// `(width + 1) / 2` bytes per row (4:2:0 chroma subsampling, rounding
        /// up for odd dimensions). The texture is recreated first if `width`/
        /// `height` differ from the last frame.
        ///
        /// - Throws: `SDL.Error` if the plane sizes are inconsistent with the
        ///   dimensions, or if SDL rejects the upload/present.
        public func present(
            width: Int, height: Int, yPlane: [UInt8], uPlane: [UInt8], vPlane: [UInt8]
        ) throws {
            let w = Int32(width)
            let h = Int32(height)
            let yPitch = width
            let chromaPitch = (width + 1) / 2
            let chromaRows = (height + 1) / 2

            // Guard the caller's plane sizes before handing raw pointers to SDL,
            // which would otherwise read out of bounds.
            guard yPlane.count >= yPitch * height,
                uPlane.count >= chromaPitch * chromaRows,
                vPlane.count >= chromaPitch * chromaRows else {
                throw Error("plane sizes too small for \(width)x\(height) frame")
            }

            if texture == nil || w != textureWidth || h != textureHeight {
                try createTexture(width: w, height: h)
            }

            let result = yPlane.withUnsafeBufferPointer { yBuf in
                uPlane.withUnsafeBufferPointer { uBuf in
                    vPlane.withUnsafeBufferPointer { vBuf in
                        SDL_UpdateYUVTexture(
                            texture, nil,
                            yBuf.baseAddress, Int32(yPitch),
                            uBuf.baseAddress, Int32(chromaPitch),
                            vBuf.baseAddress, Int32(chromaPitch)
                        )
                    }
                }
            }
            guard result == 0 else { throw Error() }

            guard SDL_RenderClear(renderer) == 0 else { throw Error() }
            guard SDL_RenderCopy(renderer, texture, nil, nil) == 0 else { throw Error() }
            SDL_RenderPresent(renderer)
        }

        /// Pump the SDL event queue and report whether the user asked to close
        /// the window (an `SDL_QUIT` or a window-close event). Call once per
        /// frame; SDL requires the event queue be pumped for the window to stay
        /// responsive.
        public func pollShouldClose() -> Bool {
            var event = SDL_Event()
            var shouldClose = false
            while SDL_PollEvent(&event) != 0 {
                if sdlkit_event_should_close(&event) != 0 {
                    shouldClose = true
                }
            }
            return shouldClose
        }

        /// (Re)create the streaming IYUV texture at the given size, destroying
        /// any previous one first.
        private func createTexture(width: Int32, height: Int32) throws {
            if let texture {
                SDL_DestroyTexture(texture)
                self.texture = nil
            }
            guard let texture = SDL_CreateTexture(
                renderer,
                sdlkit_pixelformat_iyuv(),
                sdlkit_textureaccess_streaming(),
                width, height
            ) else {
                throw Error()
            }
            self.texture = texture
            textureWidth = width
            textureHeight = height
        }
    }
}
