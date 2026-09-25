// swift-tools-version: 6.0
import PackageDescription

// One `.lproj` string catalog shared by all three apps + TailscreenHubUI.
// Keeps Apple's catalog FORMAT (`<lang>.lproj/Localizable.strings`) but
// replaces `String(localized:)`/CFBundle lookup — not portable to
// Linux/Windows — with our own parser + language-preference chain +
// `%@`/`%lld` substituter, Foundation only. Own package (not a TailscreenKit
// tier) so TailscreenHubUI can use it without pulling in RTP machinery.
let package = Package(
    name: "TailscreenL10n",
    // Keys are the English source text; this also makes SwiftPM treat the
    // `.lproj` dirs under Resources as localizations, not duplicate folders.
    defaultLocalization: "en",
    platforms: [
        .macOS("15.2")  // matches the app floor (Synchronization.Mutex is macOS 15+)
    ],
    products: [
        .library(name: "TailscreenL10n", targets: ["TailscreenL10n"])
    ],
    targets: [
        .target(
            name: "TailscreenL10n",
            resources: [
                // `.process`, not `.copy`: only the processing rule preserves
                // `.lproj` semantics (it flattens ordinary subdirectories).
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TailscreenL10nTests",
            dependencies: ["TailscreenL10n"]
        ),
    ]
)
