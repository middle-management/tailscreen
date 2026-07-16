// swift-tools-version: 6.0
import PackageDescription

// TailscreenProtocol — the platform-portable core of Tailscreen.
//
// This package compiles the wire-protocol and pure decision-logic sources
// (symlinked from ../Sources) with NO Apple framework imports, so it builds
// on Linux (and eventually Windows). It exists to (a) enforce the
// portability boundary in CI and (b) give future non-macOS clients a
// library to depend on. The macOS app does not depend on this package —
// it compiles the same files directly as part of the Tailscreen target.
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
        )
    ],
    targets: [
        .target(
            name: "TailscreenProtocol",
            path: "Sources/TailscreenProtocol"
        ),
        .testTarget(
            name: "TailscreenProtocolTests",
            dependencies: ["TailscreenProtocol"],
            path: "Tests/TailscreenProtocolTests"
        )
    ]
)
