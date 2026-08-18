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
// Six portability tiers, one source target each (test targets sit beside
// them and are not part of the tier contract):
//   - TailscreenProtocol: wire protocol + pure decision logic. NO Apple
//     frameworks, NO dependencies — Foundation/Synchronization only.
//   - TailscreenTransport: tsnet-facing peer discovery + IPN-bus watcher +
//     the shared node bring-up (TsnetNodeFactory).
//     Depends on TailscaleKit (and thus on the checked-out submodule with
//     patches applied — `make -C ../TailscaleKit apply-patches`);
//     compiling it needs only the patched header, not the built
//     libtailscale.a (that's a link-time input).
//   - TailscreenAudio: the voice path both endpoints share — the Opus codec
//     (Float32↔Int16 + 960-sample framing over OpusKit/libopus), the
//     microphone seam and its capture thread, and the RTP uplink/downlink.
//     Foundation + OpusKit + TailscreenProtocol — also builds on Linux (needs
//     libopus-dev + pkg-config). Kept out of TailscreenProtocol so that tier
//     stays dependency-free; the edge runs the other way.
//   - TailscreenViewer: the host-agnostic viewer data plane (ViewerSession
//     + the decoder/sink seams, ViewerPipeline, FrameStore).
//   - TailscreenSharer: the host-agnostic sharer data plane
//     (TailscaleScreenShareServer + the CaptureEncoding / InputInjecting
//     seams). Like the viewer tier it owns no capture, encoder, or input
//     backend — the macOS app plugs in its capture helper and CGEvent
//     injector; a Linux sharer plugs in portal/PipeWire + libavcodec.
//   - TailscreenViewerTsnet: the tsnet-backed viewer transport the Linux
//     and Windows apps drive their viewers with (see the comment on its
//     target declaration below).
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
                // The RTP audio packetizer/depacketizer, for VoiceUplink and
                // VoiceDownlink. This edge points AT the dependency-free tier,
                // so it costs nothing a consumer of the codec was not already
                // going to link, and it is what lets the two endpoints share
                // one voice path instead of one each.
                "TailscreenProtocol",
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
        // It lived in Packages/TailscreenLinuxBackends until the Windows app needed it. Nothing about
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
                // The viewer's own voice: `run` builds a `VoiceUplink` over a
                // host-supplied microphone and sends it out through the same
                // ordered queue as the control bytes.
                "TailscreenAudio",
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
            dependencies: [
                "TailscreenViewer", "TailscreenProtocol", "TailscreenAudio"
            ],
            path: "Tests/TailscreenViewerTests"
        ),
        .testTarget(
            name: "TailscreenSharerTests",
            // TailscreenTransport is named explicitly — it already arrives
            // transitively through TailscreenSharer — so
            // `SharerAskToShareCoordinatorTests` can spell
            // `TailscreenControlListener`, the type its listener-lifecycle
            // seams hand back.
            dependencies: ["TailscreenSharer", "TailscreenProtocol", "TailscreenTransport"],
            path: "Tests/TailscreenSharerTests"
        ),

        // The public Go SDK (sdk/go) built as a C static library — the same
        // c-archive mechanism as libtailscale.a. `make libtailscreen` emits
        // sdk/go/build/libtailscreen.{a,h}; sdk/go/libtailscreen.pc supplies
        // the -L/-I flags, so PKG_CONFIG_PATH must include sdk/go (the root
        // Makefile exports it — go through `make test-protocol`).
        .systemLibrary(
            name: "CTailscreen",
            path: "Modules/CTailscreen",
            pkgConfig: "libtailscreen"
        ),

        // The differential suite: the shipping Swift pipeline and the Go SDK
        // (linked via CTailscreen) driven with identical seeded input,
        // asserting identical output at every step. The conformance vectors
        // pin the stateless codecs on both sides; this target pins the
        // STATEFUL pipeline — reorder, depacketizers, NACK scheduling, FEC
        // group solving, RR accounting — where a fixed vector file cannot
        // express a clock-driven interleaving.
        .testTarget(
            name: "TailscreenDifferentialTests",
            dependencies: ["TailscreenProtocol", "CTailscreen"],
            path: "Tests/TailscreenDifferentialTests",
            linkerSettings: [
                .linkedLibrary("pthread", .when(platforms: [.linux]))
            ]
        )
    ]
)
