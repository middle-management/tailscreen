// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tailscreen-macos",
    // No `defaultLocalization:` — the `.lproj` catalogs moved to
    // Packages/TailscreenL10n when Linux and Windows started reading them
    // too, so this package no longer ships a localized resource. What's left
    // under Sources/Resources is the unlocalized PDF/SVG artwork.
    platforms: [
        // 15.2 (Dec 2024) is the floor: SCContentFilter's
        // `includedDisplays` / `includedWindows` /
        // `includedApplications` getters were introduced there, and
        // the picker-helper subprocess relies on them to extract the
        // primitives it ships across processes.
        .macOS("15.2")
    ],
    products: [
        .executable(
            name: "Tailscreen",
            targets: ["Tailscreen"]
        )
    ],
    dependencies: [
        // TailscaleKit local package
        .package(path: "../../Packages/TailscaleKit"),
        // The portable core: wire protocol + pure decision logic
        // (TailscreenProtocol), the tsnet-facing transport tier
        // (TailscreenTransport), the Opus codec tier (TailscreenAudio,
        // which pulls in OpusKit/libopus), and the two host-agnostic data
        // planes — TailscreenViewer and TailscreenSharer, whose platform
        // backends this app supplies. All build on Linux — see its README.
        .package(path: "../../Packages/TailscreenKit"),
        // The string catalog, shared with the GTK and WinUI apps. Supplies
        // `L(_:)` and the `.lproj`s behind it; re-exported through
        // Sources/ProtocolReexports.swift so call sites stay bare `L("…")`.
        .package(path: "../../Packages/TailscreenL10n")
    ],
    targets: [
        .executableTarget(
            name: "Tailscreen",
            dependencies: [
                .product(name: "TailscaleKit", package: "TailscaleKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscreenL10n", package: "TailscreenL10n")
            ],
            path: "Sources",
            resources: [
                // Vector PDF used as the menubar template image (loaded
                // via Bundle.module and rendered with isTemplate = true).
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
        .testTarget(
            name: "TailscreenTests",
            dependencies: [
                "Tailscreen",
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenSharer", package: "TailscreenKit")
            ],
            path: "Tests/TailscreenTests",
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        )
    ]
)
