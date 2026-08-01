// swift-tools-version: 6.0
import PackageDescription

// TailscreenVideoFFmpeg — libavcodec behind the portable `VideoDecoding` seam.
//
// A package of its own rather than a target in either neighbour, for reasons
// that are the whole point of it existing:
//
//   • Not in Apps/linux. It lived there, next to the ALSA sink, which meant a
//     consumer wanting only the decoder inherited ALSAKit and X11CaptureKit as
//     package dependencies. That is exactly what kept the tsnet transport
//     unusable on Windows until W3 moved it, and the decoder had the same
//     problem for the same reason.
//   • Not in TailscreenKit. `swift test` there builds every target, so folding
//     this in would make the cheap `linux-protocol` portability gate require
//     libavcodec-dev — turning a Foundation-only tier into one that needs a
//     video codec installed to check that it is still Foundation-only.
//   • Not in FFmpegKit. That package is a thin wrapper over the system library
//     with no knowledge of Tailscreen; giving it a dependency on our protocol
//     types would invert the layering and drag TailscreenKit into its tests.
//
// So: FFmpegKit + TailscreenKit in, one conformance out. Both the Linux viewer
// and the Windows viewer consume it.
let package = Package(
    name: "TailscreenVideoFFmpeg",
    products: [
        .library(name: "TailscreenVideoFFmpeg", targets: ["TailscreenVideoFFmpeg"])
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
        )
    ]
)
