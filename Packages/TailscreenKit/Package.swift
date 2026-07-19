// swift-tools-version: 6.0
import PackageDescription

// TailscreenKit — the platform-portable core of Tailscreen.
//
// These sources live only here and build on Linux (and eventually
// Windows). The macOS app consumes this package as a real SwiftPM
// dependency (re-exported via Sources/ProtocolReexports.swift), so the
// package's public API is the app's compile-time contract. CI enforces
// the portability boundary (linux-protocol job).
//
// Three portability tiers, three targets:
//   - TailscreenProtocol: wire protocol + pure decision logic. NO Apple
//     frameworks, NO dependencies — Foundation/Synchronization only.
//   - TailscreenTransport: tsnet-facing peer discovery + IPN-bus watcher.
//     Depends on TailscaleKit (and thus on the checked-out submodule with
//     patches applied — `make -C ../TailscaleKit apply-patches`);
//     compiling it needs only the patched header, not the built
//     libtailscale.a (that's a link-time input).
//   - TailscreenAudio: the Opus voice/system-audio codec (Float32↔Int16 +
//     960-sample framing over OpusKit/libopus). Foundation + OpusKit only —
//     also builds on Linux (needs libopus-dev + pkg-config). Kept out of
//     TailscreenProtocol so that tier stays dependency-free.
let package = Package(
    name: "TailscreenKit",
    platforms: [
        // Match the app's floor so Apple-platform builds of this package
        // see the same availability window (irrelevant on Linux).
        .macOS("15.2")
    ],
    products: [
        .library(
            name: "TailscreenProtocol",
            targets: ["TailscreenProtocol"]
        ),
        .library(
            name: "TailscreenTransport",
            targets: ["TailscreenTransport"]
        ),
        .library(
            name: "TailscreenAudio",
            targets: ["TailscreenAudio"]
        ),
        .library(
            name: "TailscreenViewer",
            targets: ["TailscreenViewer"]
        )
    ],
    dependencies: [
        .package(path: "../TailscaleKit"),
        .package(path: "../OpusKit")
    ],
    targets: [
        .target(
            name: "TailscreenProtocol",
            path: "Sources/TailscreenProtocol"
        ),
        .target(
            name: "TailscreenTransport",
            dependencies: [
                "TailscreenProtocol",
                .product(name: "TailscaleKit", package: "TailscaleKit")
            ],
            path: "Sources/TailscreenTransport"
        ),
        .target(
            name: "TailscreenAudio",
            dependencies: [
                .product(name: "OpusKit", package: "OpusKit")
            ],
            path: "Sources/TailscreenAudio"
        ),
        .target(
            name: "TailscreenViewer",
            dependencies: [
                "TailscreenProtocol",
                "TailscreenAudio"
            ],
            path: "Sources/TailscreenViewer"
        ),
        .testTarget(
            name: "TailscreenProtocolTests",
            dependencies: ["TailscreenProtocol", "TailscreenAudio"],
            path: "Tests/TailscreenProtocolTests"
        ),
        .testTarget(
            name: "TailscreenViewerTests",
            dependencies: ["TailscreenViewer", "TailscreenProtocol", "TailscreenAudio"],
            path: "Tests/TailscreenViewerTests"
        )
    ]
)
