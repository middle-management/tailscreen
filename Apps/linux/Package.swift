// swift-tools-version: 6.0
import PackageDescription

// Shared library package for the portable (Linux/Windows) screen-share viewer.
// It plugs concrete backends into the portable `ViewerSession` data-plane core
// (Packages/TailscreenKit's TailscreenViewer target):
//
//   • video decode  — FFmpegKit (libavcodec)      → VideoDecoding
//   • audio output   — ALSAKit (libasound)         → AudioSink
//   • transport      — TailscaleKit (tsnet UDP)    → receiveRTP / onControlToSend / tick
//
// The concrete video RENDER surface is NOT here: the native GTK viewer
// (Apps/linux-gtk) owns it (a `GtkGLArea` YUV renderer) and reuses these
// targets. Split into small targets so (a) the decode→audio pipeline is
// CI-testable without the tsnet/Go dependency, and (b) the transport is
// isolated:
//
//   • `TailscreenViewerCore` (library): FFmpeg decoder + ALSA sink (+ the
//     `ThreadedAudioSink` wrapper) + the `ViewerPipeline`. Foundation +
//     FFmpeg/ALSA/Opus only — no libtailscale — so `swift test` builds it with
//     just apt ffmpeg/alsa/opus.
//   • `TailscreenViewerTsnet` (library): the tsnet transport. Adds TailscaleKit
//     (→ libtailscale.a) + TailscreenTransport. Consumed by the GTK viewer.
//
// No `platforms:` clause on purpose — this is the Linux/Windows viewer.
let package = Package(
    name: "tailscreen-viewer",
    products: [
        .library(name: "TailscreenViewerCore", targets: ["TailscreenViewerCore"]),
        .library(name: "TailscreenViewerTsnet", targets: ["TailscreenViewerTsnet"]),
    ],
    dependencies: [
        .package(path: "../../Packages/FFmpegKit"),
        .package(path: "../../Packages/ALSAKit"),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscaleKit"),
    ],
    targets: [
        // FFmpeg decoder + ALSA sink + ViewerPipeline. No tsnet, so it builds
        // and tests without libtailscale.
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
        // The tsnet transport (consumed by the GTK viewer). Pulls TailscaleKit
        // (libtailscale.a) + TailscreenTransport (IPN watcher/auth).
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
