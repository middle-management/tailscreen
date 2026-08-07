// swift-tools-version: 6.0
import PackageDescription

// TailscreenVideoFFmpeg — libavcodec behind portable seams, one target per
// side: the `TailscreenVideoFFmpeg` DECODER target (the portable
// `VideoDecoding` conformance the Linux and Windows viewers share) and the
// `TailscreenSharerFFmpegBase` ENCODER-scaffolding target (the base class the
// three FFmpeg-based `CaptureEncoding` backends — X11, WGC, portal — share).
//
// A package of its own rather than a target in either neighbour, for reasons
// that are the whole point of it existing:
//
//   • Not in Packages/TailscreenLinuxBackends. It lived there, next to the ALSA sink, which meant a
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
// The sharer base is a SEPARATE target (and product) so the two sides' link
// lines stay independent: a viewer-only consumer of the decoder pulls
// FFmpegKit + TailscreenViewer as before, and a sharer backend pulls the base
// (FFmpegKit + TailscreenProtocol) without acquiring the decoder. Deliberately
// no TailscreenSharer dependency on the base — the `CaptureEncoding`
// conformance is declared by each backend, which keeps this package's test
// bundle free of the libtailscale archive that `TailscreenSharer` links.
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
        // The encode-send scaffolding shared by the three non-mac capture
        // backends. FFmpegKit + the dependency-free protocol tier ONLY — see
        // the package comment above for why not TailscreenSharer.
        .target(
            name: "TailscreenSharerFFmpegBase",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit")
            ],
            path: "Sources/TailscreenSharerFFmpegBase"
        ),
        // The base's pure decisions: ladder ordering, the source-gone failure
        // budget, bitrate anchoring, quality-env decode, pacing math. Links
        // libavcodec (FFmpegKit) but no libtailscale.
        .testTarget(
            name: "TailscreenSharerFFmpegBaseTests",
            dependencies: ["TailscreenSharerFFmpegBase"],
            path: "Tests/TailscreenSharerFFmpegBaseTests"
        )
    ]
)
