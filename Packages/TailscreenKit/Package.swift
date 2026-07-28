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
//   - TailscreenViewer: the host-agnostic viewer data plane (ViewerSession
//     + the decoder/sink seams, ViewerPipeline, FrameStore).
//   - TailscreenSharer: the host-agnostic sharer data plane
//     (TailscaleScreenShareServer + the CaptureEncoding / InputInjecting
//     seams). Like the viewer tier it owns no capture, encoder, or input
//     backend — the macOS app plugs in its capture helper and CGEvent
//     injector; a Linux sharer plugs in portal/PipeWire + libavcodec.
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
        ),
        .library(
            name: "TailscreenSharer",
            targets: ["TailscreenSharer"]
        ),
        .library(
            name: "TailscreenViewerTsnet",
            targets: ["TailscreenViewerTsnet"]
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
        .target(
            name: "TailscreenSharer",
            dependencies: [
                "TailscreenProtocol",
                "TailscreenTransport",
                .product(name: "TailscaleKit", package: "TailscaleKit")
            ],
            path: "Sources/TailscreenSharer"
        ),
        // The viewer's tsnet transport: node bring-up (incl. the interactive
        // browser-login URL), peer discovery, the UDP media socket and the TCP
        // back-channel, assembled onto ViewerPipeline.
        //
        // It lived in Apps/linux until the Windows app needed it. Nothing about
        // it was ever Linux-specific — it is Foundation + TailscaleKit + the
        // portable tiers, and the `import TailscreenViewerCore` that tied it to
        // FFmpeg and ALSA referenced no symbol from that module at all. Moving
        // it here lets a host consume the transport without also acquiring a
        // video decoder and an audio backend it may implement differently.
        //
        // Like TailscreenTransport, compiling this needs only the patched
        // libtailscale header; the archive is a link-time input, so the `-L`
        // flag belongs on the executable that links it, not here.
        .target(
            name: "TailscreenViewerTsnet",
            dependencies: [
                "TailscreenProtocol",
                "TailscreenTransport",
                "TailscreenViewer",
                .product(name: "TailscaleKit", package: "TailscaleKit")
            ],
            path: "Sources/TailscreenViewerTsnet"
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
