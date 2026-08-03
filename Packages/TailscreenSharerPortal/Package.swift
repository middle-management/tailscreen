// swift-tools-version: 6.0
import PackageDescription

// The LINUX sharer's ScreenCast-portal `CaptureEncoding` backend: PipeWire
// frames (BGRA) → the portable `BGRAToI420` → libavcodec.
//
// A SEPARATE package from TailscreenLinuxBackends, for the same reason
// TailscreenSharerWGC is separate on Windows and TailscreenVideoFFmpeg is
// separate from the decoder's consumers: consuming one backend should not drag
// in the system libraries of another. Folding this into TailscreenSharerLinux
// would put libdbus and libpipewire on the link line of every viewer-only run
// and every headless test-sharer — and would make the `linux-viewer` CI job,
// which exists to gate the FFmpeg/ALSA pipeline, start failing on a missing
// PipeWire header. Same argument X11HotkeyKit makes for not living inside
// XTestInjectKit.
//
// It carries no UI and no transport, so Linux CI typechecks and tests it in
// full — which matters more here than anywhere else in the repo, because the
// portal itself can never be gated headlessly (see PortalCapturePlan).
let package = Package(
    name: "TailscreenSharerPortal",
    products: [
        .library(name: "TailscreenSharerPortal", targets: ["TailscreenSharerPortal"])
    ],
    dependencies: [
        .package(path: "../PortalCaptureKit"),
        .package(path: "../FFmpegKit"),
        .package(path: "../TailscreenKit"),
    ],
    targets: [
        .target(
            name: "TailscreenSharerPortal",
            dependencies: [
                .product(name: "PortalCaptureKit", package: "PortalCaptureKit"),
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                // The seam this conforms to, and the colour conversion +
                // arm/rebuild decisions it runs on.
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/TailscreenSharerPortal"
        ),
        // The buffer hand-off's tests run real threads against real
        // contention. They need no portal and no PipeWire daemon, which is
        // the entire reason that type was pulled out of the encoder.
        .testTarget(
            name: "TailscreenSharerPortalTests",
            dependencies: ["TailscreenSharerPortal"],
            path: "Tests/TailscreenSharerPortalTests"
        ),
    ]
)
