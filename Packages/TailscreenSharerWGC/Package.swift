// swift-tools-version: 6.0
import PackageDescription

// TailscreenSharerWGC — Windows.Graphics.Capture + libavcodec behind the
// portable `CaptureEncoding` seam. Windows counterpart of
// `TailscreenLinuxBackends`'s `TailscreenSharerLinux`.
//
// Own package (not in Apps/windows) so it needs no WinUI and typechecks on
// Linux — a capture-loop mistake is a red Linux build in seconds instead of a
// Windows link error later. Not in WGCCaptureKit (would invert the layering:
// that's a thin WinRT shim with no protocol knowledge) or in TailscreenKit
// (would force the cheap `linux-protocol` gate to need libavcodec). BGRA→I420
// and the NAL-type table stay in TailscreenProtocol, where Linux CI tests them.
let package = Package(
    name: "TailscreenSharerWGC",
    products: [
        .library(name: "TailscreenSharerWGC", targets: ["TailscreenSharerWGC"])
    ],
    dependencies: [
        .package(path: "../WGCCaptureKit"),
        .package(path: "../FFmpegKit"),
        .package(path: "../TailscreenKit"),
        .package(path: "../TailscreenVideoFFmpeg"),
        .package(path: "../SendInputKit"),
        .package(path: "../TailscaleKit"),
        .package(path: "../WinOverlayKit"),
    ],
    targets: [
        .target(
            name: "TailscreenSharerWGC",
            dependencies: [
                .product(name: "WGCCaptureKit", package: "WGCCaptureKit"),
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                // Encode-send scaffolding shared with the X11 and portal backends.
                .product(name: "TailscreenSharerFFmpegBase", package: "TailscreenVideoFFmpeg"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "SendInputKit", package: "SendInputKit"),
                // The share runs on the app's already-signed-in node; see beginSharing.
                .product(name: "TailscaleKit", package: "TailscaleKit"),
                .product(name: "WinOverlayKit", package: "WinOverlayKit"),
            ],
            path: "Sources/TailscreenSharerWGC"
        ),
        // Windows share ENGINE suite: everything Windows-bound stubs out off
        // Windows, so `WindowsShareSession` is driven headless on Linux CI
        // (`Apps/windows` itself has no test target). Runs on `linux-viewer`.
        .testTarget(
            name: "TailscreenSharerWGCTests",
            dependencies: [
                "TailscreenSharerWGC",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
            ],
            path: "Tests/TailscreenSharerWGCTests"
        )
    ]
)
