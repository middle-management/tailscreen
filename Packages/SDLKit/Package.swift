// swift-tools-version: 6.0
import PackageDescription

// SDLKit — a thin, portable Swift wrapper over the system SDL2, for the
// Linux/Windows viewer's video output where the macOS app uses Metal.
//
// The FFmpeg decoder emits 8-bit planar YUV 4:2:0; SDL's IYUV streaming
// texture does the YUV→RGB conversion in the renderer (GPU where available),
// which is exactly the cheap, portable render path a non-macOS viewer wants.
// Wrapped the same way TailscaleKit wraps libtailscale / OpusKit wraps
// libopus — a `systemLibrary` target (`CSDL2`) + a Foundation-only Swift
// wrapper (`SDLKit`) — so it builds against a system SDL2 (apt
// `libsdl2-dev`, brew `sdl2`, vcpkg `sdl2`).
let package = Package(
    name: "SDLKit",
    products: [
        .library(name: "SDLKit", targets: ["SDLKit"])
    ],
    targets: [
        .systemLibrary(
            name: "CSDL2",
            path: "Sources/CSDL2",
            pkgConfig: "sdl2",
            providers: [.apt(["libsdl2-dev"]), .brew(["sdl2"])]
        ),
        .target(
            name: "SDLKit",
            dependencies: ["CSDL2"],
            path: "Sources/SDLKit"
        ),
        .testTarget(
            name: "SDLKitTests",
            dependencies: ["SDLKit", "CSDL2"],
            path: "Tests/SDLKitTests"
        )
    ]
)
