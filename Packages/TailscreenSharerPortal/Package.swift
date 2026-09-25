// swift-tools-version: 6.0
import PackageDescription

// LINUX sharer's ScreenCast-portal `CaptureEncoding` backend: PipeWire frames
// (BGRA) → the portable `BGRAToI420` → libavcodec.
//
// Separate package from TailscreenLinuxBackends: folding it in would put
// libdbus/libpipewire on the link line of every viewer-only run and headless
// test-sharer, and would make `linux-viewer` (gates FFmpeg/ALSA) fail on a
// missing PipeWire header.
let package = Package(
    name: "TailscreenSharerPortal",
    products: [
        .library(name: "TailscreenSharerPortal", targets: ["TailscreenSharerPortal"])
    ],
    dependencies: [
        .package(path: "../PortalCaptureKit"),
        .package(path: "../FFmpegKit"),
        .package(path: "../TailscreenKit"),
        .package(path: "../TailscreenVideoFFmpeg"),
    ],
    targets: [
        .target(
            name: "TailscreenSharerPortal",
            dependencies: [
                .product(name: "PortalCaptureKit", package: "PortalCaptureKit"),
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // Encode-send scaffolding shared with the X11 and WGC backends.
                .product(name: "TailscreenSharerFFmpegBase", package: "TailscreenVideoFFmpeg"),
            ],
            path: "Sources/TailscreenSharerPortal"
        ),
        // Runs real threads against real contention; needs no portal/PipeWire
        // daemon, which is why this type was pulled out of the encoder.
        .testTarget(
            name: "TailscreenSharerPortalTests",
            dependencies: ["TailscreenSharerPortal"],
            path: "Tests/TailscreenSharerPortalTests"
        ),
    ]
)
