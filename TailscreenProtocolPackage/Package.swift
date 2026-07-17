// swift-tools-version: 6.0
import PackageDescription

// TailscreenProtocol — the platform-portable core of Tailscreen.
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
//     patches applied — `make -C ../TailscaleKitPackage apply-patches`);
//     compiling it needs only the patched header, not the built
//     libtailscale.a (that's a link-time input).
//   - TailscreenAudio: the Opus voice/system-audio codec (Float32↔Int16 +
//     960-sample framing over OpusKit/libopus). Foundation + OpusKit only —
//     also builds on Linux (needs libopus-dev + pkg-config). Kept out of
//     TailscreenProtocol so that tier stays dependency-free.
let package = Package(
    name: "TailscreenProtocol",
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
        )
    ],
    dependencies: [
        .package(path: "../TailscaleKitPackage"),
        .package(path: "../OpusKitPackage")
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
                .product(name: "TailscaleKit", package: "TailscaleKitPackage")
            ],
            path: "Sources/TailscreenTransport"
        ),
        .target(
            name: "TailscreenAudio",
            dependencies: [
                .product(name: "OpusKit", package: "OpusKitPackage")
            ],
            path: "Sources/TailscreenAudio"
        ),
        .testTarget(
            name: "TailscreenProtocolTests",
            dependencies: ["TailscreenProtocol", "TailscreenAudio"],
            path: "Tests/TailscreenProtocolTests"
        )
    ]
)
