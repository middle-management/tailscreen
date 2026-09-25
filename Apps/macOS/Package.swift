// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tailscreen-macos",
    // No `defaultLocalization:` — the `.lproj` catalogs live in
    // Packages/TailscreenL10n; Sources/Resources is unlocalized PDF/SVG only.
    platforms: [
        // 15.2 floor: SCContentFilter's `includedDisplays`/`includedWindows`/
        // `includedApplications` getters, which the picker-helper needs.
        .macOS("15.2")
    ],
    products: [
        .executable(
            name: "Tailscreen",
            targets: ["Tailscreen"]
        )
    ],
    dependencies: [
        .package(path: "../../Packages/TailscaleKit"),
        // The portable core: protocol, tsnet transport, Opus audio, and the
        // host-agnostic viewer/sharer data planes this app backs.
        .package(path: "../../Packages/TailscreenKit"),
        // The string catalog shared with the GTK/WinUI apps, re-exported via
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
                // Vector PDF for the menubar template image (Bundle.module,
                // isTemplate = true).
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
