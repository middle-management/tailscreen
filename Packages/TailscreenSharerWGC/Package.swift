// swift-tools-version: 6.0
import PackageDescription

// TailscreenSharerWGC — Windows.Graphics.Capture + libavcodec behind the
// portable `CaptureEncoding` seam. The Windows counterpart of
// `Packages/TailscreenLinuxBackends`'s `TailscreenSharerLinux`.
//
// A package of its own, and for the reason that matters most here: **it does
// not need WinUI, so it can be typechecked on Linux.** Put in
// `Apps/windows` — the obvious home, next to the app that uses it — it would
// inherit swift-cross-ui and the Windows App SDK, and the only machine that
// could compile it would be a Windows runner eleven minutes into a job. Here,
// its dependencies are WGCCaptureKit (which stubs out to `unsupportedPlatform`
// off Windows), FFmpegKit and TailscreenKit — all of which build on Linux, so
// a mistake in the capture loop is a red Linux build in seconds rather than a
// Windows link error much later.
//
// The same reasoning TailscreenVideoFFmpeg's manifest sets out for the
// decoder, applied to the encoder:
//
//   • Not in WGCCaptureKit. That package is a thin shim over WinRT with no
//     knowledge of Tailscreen; giving it our protocol types would invert the
//     layering.
//   • Not in TailscreenKit. `swift test` there builds every target, so this
//     would make the cheap `linux-protocol` gate require libavcodec — turning
//     a Foundation-only tier into one that needs a video codec installed to
//     check that it is still Foundation-only.
//
// Only the platform half lives here. The BGRA→I420 conversion is
// `BGRAToI420` in TailscreenProtocol and the NAL-type table is
// `ParameterSetExtraction` beside it, both because Linux CI runs their tests
// and neither has anything Windows-specific in it.
let package = Package(
    name: "TailscreenSharerWGC",
    products: [
        .library(name: "TailscreenSharerWGC", targets: ["TailscreenSharerWGC"])
    ],
    dependencies: [
        .package(path: "../WGCCaptureKit"),
        .package(path: "../FFmpegKit"),
        .package(path: "../TailscreenKit"),
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
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                // `TailscreenControlListener`: the app owns one for the whole
                // session so an incoming "please share" is answerable while
                // idle, and hands it to the share so a second one is never
                // bound to the same port.
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "SendInputKit", package: "SendInputKit"),
                // For `TailscaleNode`: the share runs on the app's already-signed-in
                // node rather than bringing up a second one. See beginSharing.
                .product(name: "TailscaleKit", package: "TailscaleKit"),
                // The annotation overlay: viewers' strokes on the sharer's screen.
                .product(name: "WinOverlayKit", package: "WinOverlayKit"),
            ],
            path: "Sources/TailscreenSharerWGC"
        )
    ]
)
