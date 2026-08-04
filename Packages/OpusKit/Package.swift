// swift-tools-version: 6.0
import PackageDescription

// OpusKit — a thin, cross-platform Swift wrapper over the system libopus.
//
// Deliberately NOT one of the SwiftPM Opus packages on the index: those are
// Apple-only and bind to AVFoundation types (AVAudioPCMBuffer/AVAudioEngine),
// which is exactly the platform coupling Tailscreen's Opus-only audio
// decision (see plans/porting-plan.md #6) is trying to avoid. Instead this
// wraps the plain C library the same way TailscaleKit wraps
// libtailscale — a `systemLibrary` target + a Foundation-only Swift wrapper —
// so it builds on macOS, Linux, and Windows against a system libopus
// (apt `libopus-dev`, brew `opus`, vcpkg `opus`).
let package = Package(
    name: "OpusKit",
    products: [
        .library(name: "OpusKit", targets: ["OpusKit"])
    ],
    targets: [
        .systemLibrary(
            name: "COpus",
            path: "Sources/COpus",
            pkgConfig: "opus",
            providers: [.apt(["libopus-dev"]), .brew(["opus"])]
        ),
        .target(
            name: "OpusKit",
            dependencies: ["COpus"],
            path: "Sources/OpusKit"
        ),
        .testTarget(
            name: "OpusKitTests",
            dependencies: ["OpusKit"],
            path: "Tests/OpusKitTests"
        )
    ]
)
