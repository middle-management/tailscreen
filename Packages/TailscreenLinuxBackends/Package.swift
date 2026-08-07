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
// (Apps/linux) owns it (a `GtkGLArea` YUV renderer) and reuses these
// targets. Split into small targets so (a) the decode→audio pipeline is
// CI-testable without the tsnet/Go dependency, and (b) the transport is
// isolated:
//
//   • `TailscreenViewerCore` (library): FFmpeg decoder + ALSA sink (+ the
//     `ThreadedAudioSink` wrapper). Foundation + FFmpeg/ALSA/Opus only — no
//     libtailscale — so `swift test` builds it with just apt ffmpeg/alsa/opus.
//
// The tsnet transport is NOT here: it lives in Packages/TailscreenKit as
// `TailscreenViewerTsnet`, because the Windows app needs it and nothing in it
// was ever Linux-specific.
//
// No `platforms:` clause on purpose — this is the Linux/Windows viewer.
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
        // XTEST injection, for the sharer's InputInjecting backend. Its own
        // package for the same reason SendInputKit is: the seam conformance
        // lives here, the Xlib calls live there, and the decisions live in
        // TailscreenProtocol where Linux CI already tests them.
        .package(path: "../XTestInjectKit"),
    ],
    targets: [
        // FFmpeg decoder + ALSA sink + ViewerPipeline. No tsnet, so it builds
        // and tests without libtailscale.
        .target(
            name: "TailscreenViewerCore",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                // Re-exported by Adapters.swift, so consumers of this target
                // keep getting FFmpegVideoDecoder without naming the package.
                .product(name: "TailscreenVideoFFmpeg", package: "TailscreenVideoFFmpeg"),
                .product(name: "ALSAKit", package: "ALSAKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // The microphone seam ALSAMicrophone.swift conforms to, and the
                // thread that pumps it.
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenViewerCore"
        ),
        // Synthetic sharer for local end-to-end runs (see its main.swift): a
        // second tsnet node speaking the sharer half of the wire protocol, so
        // the Linux viewer can be exercised without a Mac. Development/test
        // tool, not a product sharer — it captures nothing.
        .executableTarget(
            name: "TailscreenTestSharer",
            dependencies: [
                .product(name: "CFFmpeg", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // TsnetNodeFactory, the shared node bring-up.
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
            ],
            path: "Sources/TailscreenTestSharer",
            linkerSettings: [
                .unsafeFlags(["-L", "../TailscaleKit/lib"])
            ]
        ),
        // The Linux SHARER backend: X11 capture + libavcodec encode behind the
        // portable `CaptureEncoding` seam, plus `LinuxShareSession` — the
        // GTK app's share engine, here for the same reason WindowsShareSession
        // lives in TailscreenSharerWGC: no UI toolkit, so Linux CI builds and
        // tests it headless. The engine drives the portable
        // TailscaleScreenShareServer and owns the idle control listener, which
        // is why this target now sees TailscreenTransport, TailscreenAudio
        // (sharer voice) and TailscaleKit (the node handed in by the app —
        // header-only to compile; the archive is a link-time input for
        // executables and test bundles, exactly as for TailscreenViewerTsnet).
        .target(
            name: "TailscreenSharerLinux",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                // The encode-send scaffolding shared with the WGC and portal
                // backends (FFmpegKit + TailscreenProtocol only — adds no
                // system library to this link line).
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
        // Headless Linux SHARER: the portable TailscaleScreenShareServer wired
        // to the X11 capture backend. No UI — it exists to prove the extraction
        // end to end and to be what a tray/desktop UI eventually drives.
        .executableTarget(
            name: "tailscreen-sharer-linux",
            dependencies: [
                "TailscreenSharerLinux",
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
            ],
            path: "Sources/tailscreen-sharer-linux",
            linkerSettings: [
                .unsafeFlags(["-L", "../TailscaleKit/lib"])
            ]
        ),
        // Headless VIEWER probe: the real receive path (TsnetTransport +
        // ViewerSession + FFmpeg decode) with a counting sink instead of a
        // window, so an end-to-end run can be scripted and asserted.
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
                // The node-identity test reaches into the tsnet transport for
                // its (pure) naming decision — the transport itself still
                // can't run in CI, but that decision can.
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
