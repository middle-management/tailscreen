// swift-tools-version: 6.0
import PackageDescription

// TailscreenKit — the platform-portable core of Tailscreen.
//
// Builds on Linux too; the macOS app consumes it as a real SwiftPM
// dependency (re-exported via Sources/ProtocolReexports.swift), so its
// public API is the app's compile-time contract. CI enforces the
// portability boundary (linux-protocol job). Six tiers — see
// `.claude/rules/portable-packages.md` for what each depends on and owns.
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
                // RTP audio packetizer/depacketizer for VoiceUplink/VoiceDownlink.
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
        // The diagnostics merge, as something runnable. Depends only on
        // `TailscreenProtocol`, so it builds with a bare Swift toolchain — no
        // libtailscale.a, Go, or libopus — and anybody holding two bundles
        // can build it, on any platform.
        .executableTarget(
            name: "tailscreen-diagnostics-merge",
            dependencies: ["TailscreenProtocol"],
            path: "Sources/tailscreen-diagnostics-merge"
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
            // TailscreenTransport named explicitly (already arrives
            // transitively) so tests can spell `TailscreenControlListener`.
            dependencies: ["TailscreenSharer", "TailscreenProtocol", "TailscreenTransport"],
            path: "Tests/TailscreenSharerTests"
        )
    ]
)

// TailscreenDifferential is deliberately not a test target here: it links
// libtailscreen.a, and two Go c-archives can't share one binary (this
// package's test executable already links libtailscale.a).
