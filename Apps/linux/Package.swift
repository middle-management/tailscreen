// swift-tools-version: 6.0
import PackageDescription

// tailscreen-viewer — the portable (Linux/Windows) screen-share viewer.
// It plugs concrete backends into the portable `ViewerSession` data-plane core
// (Packages/TailscreenKit's TailscreenViewer target):
//
//   • video decode  — FFmpegKit (libavcodec)      → VideoDecoding
//   • video render   — SDLKit (SDL2 YUV window)    → VideoSink
//   • audio output   — ALSAKit (libasound)         → AudioSink
//   • transport      — TailscaleKit (tsnet UDP)    → receiveRTP / onControlToSend / tick
//
// Split into small targets so (a) the decode→render→audio pipeline is
// CI-testable without the tsnet/Go dependency, and (b) the render backend is
// isolated — the native GTK viewer (Apps/linux-gtk) reuses Core + Tsnet without
// linking SDL:
//
//   • `TailscreenViewerCore` (library): FFmpeg decoder + ALSA sink + the
//     `ViewerPipeline`. Foundation + FFmpeg/ALSA/Opus only — no SDL, no
//     libtailscale — so `swift test` builds it with just apt ffmpeg/alsa/opus.
//   • `TailscreenViewerSDL` (library): the SDL YUV window `VideoSink`. Adds
//     SDLKit; kept apart so a non-SDL host (the GTK viewer) needn't link it.
//   • `TailscreenViewerTsnet` (library): the tsnet transport. Adds TailscaleKit
//     (→ libtailscale.a) + TailscreenTransport. Shared by the SDL CLI and the
//     GTK viewer.
//   • `tailscreen-viewer` (executable): `main` wiring the SDL viewer.
//
// No `platforms:` clause on purpose — this is the Linux/Windows viewer.
let package = Package(
    name: "tailscreen-viewer",
    products: [
        .executable(name: "tailscreen-viewer", targets: ["TailscreenViewerCLI"]),
        .library(name: "TailscreenViewerCore", targets: ["TailscreenViewerCore"]),
        .library(name: "TailscreenViewerSDL", targets: ["TailscreenViewerSDL"]),
        .library(name: "TailscreenViewerTsnet", targets: ["TailscreenViewerTsnet"]),
    ],
    dependencies: [
        .package(path: "../../Packages/FFmpegKit"),
        .package(path: "../../Packages/SDLKit"),
        .package(path: "../../Packages/ALSAKit"),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscaleKit"),
    ],
    targets: [
        // FFmpeg decoder + ALSA sink + ViewerPipeline. No SDL, no tsnet, so it
        // builds and tests without libsdl2 or libtailscale.
        .target(
            name: "TailscreenViewerCore",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "ALSAKit", package: "ALSAKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenViewerCore"
        ),
        // The SDL YUV-window video sink — isolated so non-SDL hosts skip it.
        .target(
            name: "TailscreenViewerSDL",
            dependencies: [
                "TailscreenViewerCore",
                .product(name: "SDLKit", package: "SDLKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenViewerSDL"
        ),
        // The tsnet transport (shared by the SDL CLI and the GTK viewer). Pulls
        // TailscaleKit (libtailscale.a) + TailscreenTransport (IPN watcher/auth).
        .target(
            name: "TailscreenViewerTsnet",
            dependencies: [
                "TailscreenViewerCore",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
            ],
            path: "Sources/TailscreenViewerTsnet",
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
        // The executable: SDL viewer entry point.
        .executableTarget(
            name: "TailscreenViewerCLI",
            dependencies: [
                "TailscreenViewerCore",
                "TailscreenViewerSDL",
                "TailscreenViewerTsnet",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenViewerCLI",
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
        // Real-decode pipeline test: encode H.264 → RTP → ViewerSession →
        // FFmpeg decode → collecting sinks. No tsnet, runs on Linux CI.
        .testTarget(
            name: "TailscreenViewerCoreTests",
            dependencies: [
                "TailscreenViewerCore",
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "CFFmpeg", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Tests/TailscreenViewerCoreTests"
        ),
    ]
)
