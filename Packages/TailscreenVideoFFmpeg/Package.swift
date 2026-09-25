// swift-tools-version: 6.0
import PackageDescription

// TailscreenVideoFFmpeg — libavcodec behind portable seams: the decoder
// target (`VideoDecoding`, shared by Linux/Windows viewers) and
// `TailscreenSharerFFmpegBase` (encoder scaffolding shared by the X11/WGC/
// portal `CaptureEncoding` backends).
//
// Own package: not in TailscreenLinuxBackends (would force decoder-only
// consumers to inherit ALSAKit/X11CaptureKit); not in TailscreenKit (would
// force the `linux-protocol` gate to need libavcodec-dev); not in FFmpegKit
// (a thin system-library wrapper with no protocol knowledge — adding one
// would invert the layering).
//
// The sharer base is a separate target/product so link lines stay
// independent (decoder consumers don't acquire it, and vice versa), and has
// no TailscreenSharer dependency — each backend declares `CaptureEncoding`
// conformance itself, keeping this package's tests free of the libtailscale
// archive.
let package = Package(
    name: "TailscreenVideoFFmpeg",
    products: [
        .library(name: "TailscreenVideoFFmpeg", targets: ["TailscreenVideoFFmpeg"]),
        .library(name: "TailscreenSharerFFmpegBase", targets: ["TailscreenSharerFFmpegBase"])
    ],
    dependencies: [
        .package(path: "../FFmpegKit"),
        .package(path: "../TailscreenKit")
    ],
    targets: [
        .target(
            name: "TailscreenVideoFFmpeg",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit")
            ],
            path: "Sources/TailscreenVideoFFmpeg"
        ),
        // Encode-send scaffolding shared by the three non-mac capture backends.
        .target(
            name: "TailscreenSharerFFmpegBase",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit")
            ],
            path: "Sources/TailscreenSharerFFmpegBase"
        ),
        // Pure decisions: ladder ordering, source-gone failure budget,
        // bitrate anchoring, quality-env decode, pacing math.
        .testTarget(
            name: "TailscreenSharerFFmpegBaseTests",
            dependencies: ["TailscreenSharerFFmpegBase"],
            path: "Tests/TailscreenSharerFFmpegBaseTests"
        )
    ]
)
