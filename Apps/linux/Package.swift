// swift-tools-version: 6.0
import PackageDescription

// tailscreen-viewer — the portable (Linux/Windows) screen-share viewer
// executable. It's the host that finally plugs the concrete backends into the
// portable `ViewerSession` data-plane core (Packages/TailscreenKit's
// TailscreenViewer target):
//
//   • video decode  — FFmpegKit (libavcodec)      → VideoDecoding
//   • video render   — SDLKit (SDL2 YUV window)    → VideoSink
//   • audio output   — ALSAKit (libasound)         → AudioSink
//   • transport      — TailscaleKit (tsnet UDP)    → receiveRTP / onControlToSend / tick
//
// The package is split so the decode→render→audio pipeline is CI-testable
// without the tsnet/Go dependency:
//
//   • `TailscreenViewerCore` (library): the three adapters + `ViewerPipeline`.
//     Depends only on FFmpegKit / SDLKit / ALSAKit / TailscreenViewer —
//     Foundation + system A/V libs, no libtailscale, so `swift test` builds
//     it with just apt ffmpeg/sdl2/alsa/opus (no Go build). This is where the
//     real-decode integration test lives.
//   • `tailscreen-viewer` (executable): `main` + the tsnet transport. Adds the
//     TailscaleKit dependency (and thus the built `libtailscale.a`), so it's a
//     separate compile gate; a *live* run needs a tailnet and is local-only.
// No `platforms:` clause on purpose — this is the Linux/Windows viewer.
// ALSAKit (libasound) has no macOS backend, so the package is not meant to
// build on macOS; on Linux SwiftPM ignores the platforms field entirely.
let package = Package(
    name: "tailscreen-viewer",
    products: [
        .executable(name: "tailscreen-viewer", targets: ["TailscreenViewerCLI"]),
        .library(name: "TailscreenViewerCore", targets: ["TailscreenViewerCore"]),
    ],
    dependencies: [
        .package(path: "../../Packages/FFmpegKit"),
        .package(path: "../../Packages/SDLKit"),
        .package(path: "../../Packages/ALSAKit"),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscaleKit"),
    ],
    targets: [
        // The host-agnostic pipeline: adapters bridging the concrete A/V
        // backends to the portable ViewerSession seam, plus the object that
        // owns a session + its sinks. No tsnet here, so it builds and tests
        // without libtailscale.
        .target(
            name: "TailscreenViewerCore",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "SDLKit", package: "SDLKit"),
                .product(name: "ALSAKit", package: "ALSAKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenViewerCore"
        ),
        // The executable: tsnet transport + argument parsing + run loop. Pulls
        // in TailscaleKit (libtailscale.a), so build it as its own gate.
        .executableTarget(
            name: "TailscreenViewerCLI",
            dependencies: [
                "TailscreenViewerCore",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // TailscaleIPNWatcher — surfaces the interactive-login
                // BrowseToURL so a keyless run can log in via a browser.
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
            ],
            path: "Sources/TailscreenViewerCLI",
            linkerSettings: [
                // Same relative -L the app uses so the CFFmpeg/… link flags
                // resolve libtailscale.a. Kept relative for portability/CI.
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
                // Raw libavcodec, to encode real H.264 to feed the pipeline.
                .product(name: "CFFmpeg", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Tests/TailscreenViewerCoreTests"
        ),
    ]
)
