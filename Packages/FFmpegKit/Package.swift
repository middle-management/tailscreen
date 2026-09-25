// swift-tools-version: 6.0
import PackageDescription

// FFmpegKit — a thin, cross-platform Swift wrapper over the system FFmpeg
// video decoder (libavcodec / libavutil): the Linux/Windows viewer's
// video-decode backend, where macOS decodes with VideoToolbox instead.
// Wrapped like OpusKit wraps libopus — a `systemLibrary` target (`CFFmpeg`)
// + a Foundation-only Swift wrapper (`FFmpegKit`) — against a system FFmpeg
// (apt `libavcodec-dev`, brew `ffmpeg`, vcpkg `ffmpeg`).
let package = Package(
    name: "FFmpegKit",
    products: [
        .library(name: "FFmpegKit", targets: ["FFmpegKit"]),
        // The raw libavcodec module is exported so a consumer's tests can drive
        // the C API directly — e.g. to generate real H.264 bitstream to feed
        // through the decoder (the Linux viewer's pipeline integration test
        // does exactly this, mirroring FFmpegKit's own round-trip test).
        .library(name: "CFFmpeg", targets: ["CFFmpeg"]),
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            // libavcodec.pc `Requires: libavutil`, so pkg-config pulls avutil's
            // cflags/libs in too; the module map links both explicitly.
            pkgConfig: "libavcodec",
            providers: [
                .apt(["libavcodec-dev", "libavutil-dev"]),
                .brew(["ffmpeg"])
            ]
        ),
        .target(
            name: "FFmpegKit",
            dependencies: ["CFFmpeg"],
            path: "Sources/FFmpegKit"
        ),
        .testTarget(
            name: "FFmpegKitTests",
            // The round-trip test drives libavcodec's encoder directly to
            // produce real H.264 to decode, so it imports CFFmpeg too.
            dependencies: ["FFmpegKit", "CFFmpeg"],
            path: "Tests/FFmpegKitTests"
        )
    ]
)
