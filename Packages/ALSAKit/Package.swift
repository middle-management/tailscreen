// swift-tools-version: 6.0
import PackageDescription

// ALSAKit — a thin Swift wrapper over the system ALSA client library
// (libasound) for the Linux viewer's audio playback. ALSA is the lowest
// common denominator on Linux: even PipeWire and PulseAudio ship an
// ALSA-compatibility PCM, so it's a safe portable first backend.
//
// Wrapped like OpusKit wraps libopus and TailscaleKit wraps libtailscale — a
// `systemLibrary` target (`CALSA`) plus a Foundation-only Swift wrapper
// (`ALSAKit`) — against a system libasound (apt `libasound2-dev`).
let package = Package(
    name: "ALSAKit",
    products: [
        .library(name: "ALSAKit", targets: ["ALSAKit"])
    ],
    targets: [
        .systemLibrary(
            name: "CALSA",
            path: "Sources/CALSA",
            pkgConfig: "alsa",
            providers: [.apt(["libasound2-dev"])]
        ),
        .target(
            name: "ALSAKit",
            dependencies: ["CALSA"],
            path: "Sources/ALSAKit"
        ),
        .testTarget(
            name: "ALSAKitTests",
            dependencies: ["ALSAKit", "CALSA"],
            path: "Tests/ALSAKitTests"
        )
    ]
)
