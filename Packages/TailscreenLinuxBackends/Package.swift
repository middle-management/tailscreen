// swift-tools-version: 6.0
import PackageDescription

// Concrete backends for the portable (Linux/Windows) screen-share viewer,
// plugged into TailscreenKit's `ViewerSession` core: FFmpegKit → VideoDecoding,
// ALSAKit → AudioSink. Render surface stays in Apps/linux (GtkGLArea). Split
// into small targets so the decode→audio pipeline (`TailscreenViewerCore`,
// no libtailscale) is CI-testable without the tsnet/Go dependency; tsnet
// transport itself lives in TailscreenKit's `TailscreenViewerTsnet` (also
// needed by Windows). No `platforms:` clause — this is the Linux/Windows side.
let package = Package(
    name: "TailscreenLinuxBackends",
    products: [
        .library(name: "TailscreenViewerCore", targets: ["TailscreenViewerCore"]),
        .library(name: "TailscreenSharerLinux", targets: ["TailscreenSharerLinux"]),
    ],
    dependencies: [
        .package(path: "../FFmpegKit"),
        .package(path: "../TailscreenVideoFFmpeg"),
        .package(path: "../ALSAKit"),
        .package(path: "../TailscreenKit"),
        .package(path: "../TailscaleKit"),
        .package(path: "../X11CaptureKit"),
        // Own package for the same reason SendInputKit is on Windows.
        .package(path: "../XTestInjectKit"),
    ],
    targets: [
        // FFmpeg decoder + ALSA sink + ViewerPipeline. No tsnet, so it builds
        // and tests without libtailscale.
        .target(
            name: "TailscreenViewerCore",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                // Re-exported by Adapters.swift.
                .product(name: "TailscreenVideoFFmpeg", package: "TailscreenVideoFFmpeg"),
                .product(name: "ALSAKit", package: "ALSAKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenViewerCore"
        ),
        // Synthetic sharer for local end-to-end runs: a second tsnet node
        // speaking the sharer half of the protocol so the Linux viewer can be
        // exercised without a Mac. Test tool only — captures nothing.
        .executableTarget(
            name: "TailscreenTestSharer",
            dependencies: [
                .product(name: "CFFmpeg", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
            ],
            path: "Sources/TailscreenTestSharer",
            linkerSettings: [
                .unsafeFlags(["-L", "../TailscaleKit/lib"])
            ]
        ),
        // The Linux SHARER backend: X11 capture + libavcodec encode behind
        // `CaptureEncoding`, plus `LinuxShareSession` — the GTK app's share
        // engine, here (as with Windows' WindowsShareSession) so Linux CI
        // builds and tests it headless with no UI toolkit.
        .target(
            name: "TailscreenSharerLinux",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenSharerFFmpegBase", package: "TailscreenVideoFFmpeg"),
                .product(name: "X11CaptureKit", package: "X11CaptureKit"),
                .product(name: "XTestInjectKit", package: "XTestInjectKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
            ],
            path: "Sources/TailscreenSharerLinux"
        ),
        // Headless Linux SHARER: TailscaleScreenShareServer wired to the X11
        // capture backend. No UI.
        .executableTarget(
            name: "tailscreen-sharer-linux",
            dependencies: [
                "TailscreenSharerLinux",
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
            ],
            path: "Sources/tailscreen-sharer-linux",
            linkerSettings: [
                .unsafeFlags(["-L", "../TailscaleKit/lib"])
            ]
        ),
        // Headless VIEWER probe: real receive path with a counting sink
        // instead of a window, for scripted end-to-end runs.
        .executableTarget(
            name: "tailscreen-viewer-probe",
            dependencies: [
                "TailscreenViewerCore",
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit"),
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/tailscreen-viewer-probe",
            linkerSettings: [
                .unsafeFlags(["-L", "../TailscaleKit/lib"])
            ]
        ),
        // Real-decode pipeline test: encode H.264 → RTP → ViewerSession →
        // FFmpeg decode → collecting sinks. No tsnet, runs on Linux CI.
        .testTarget(
            name: "TailscreenViewerCoreTests",
            dependencies: [
                "TailscreenViewerCore",
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit"),
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "CFFmpeg", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Tests/TailscreenViewerCoreTests"
        ),
        // Capture → encode → decode, through the real CaptureEncoding seam.
        // Needs a display; self-skips without one, runs under Xvfb in CI.
        .testTarget(
            name: "TailscreenSharerLinuxTests",
            dependencies: [
                "TailscreenSharerLinux",
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
            ],
            path: "Tests/TailscreenSharerLinuxTests"
        ),
    ]
)
