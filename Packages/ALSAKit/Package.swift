// swift-tools-version: 6.0
import PackageDescription

// ALSAKit — a thin Swift wrapper over the system ALSA client library
// (libasound) for the Linux viewer's audio playback.
//
// The macOS viewer plays decoded audio through AVAudioEngine; that whole
// stack is Apple-only, so a Linux port needs a native output backend. ALSA is
// the lowest common denominator on Linux: even PipeWire and PulseAudio ship an
// ALSA-compatibility PCM (the `pulse`/`pipewire` plugins, and `default`
// usually routes through them), so an ALSA writer is the safe portable first
// cut before a dedicated PipeWire backend.
//
// Wrapped the same way OpusKit wraps libopus and TailscaleKit wraps
// libtailscale — a `systemLibrary` target (`CALSA`) plus a Foundation-only
// Swift wrapper (`ALSAKit`) — so it builds against a system libasound
// (apt `libasound2-dev`). ALSA is Linux-only, so this package is too.
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
