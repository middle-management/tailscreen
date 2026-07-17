// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tailscreen",
    defaultLocalization: "en",
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
        .package(path: "./TailscaleKitPackage"),
        // The portable core: wire protocol + pure decision logic
        // (TailscreenProtocol), the tsnet-facing transport tier
        // (TailscreenTransport), and the Opus codec tier (TailscreenAudio,
        // which pulls in OpusKit/libopus). All build on Linux — see its README.
        .package(path: "./TailscreenProtocolPackage")
    ],
    targets: [
        .executableTarget(
            name: "Tailscreen",
            dependencies: [
                .product(name: "TailscaleKit", package: "TailscaleKitPackage"),
                .product(name: "TailscreenProtocol", package: "TailscreenProtocolPackage"),
                .product(name: "TailscreenTransport", package: "TailscreenProtocolPackage"),
                .product(name: "TailscreenAudio", package: "TailscreenProtocolPackage")
            ],
            path: "Sources",
            resources: [
                // Vector PDF used as the menubar template image (loaded
                // via Bundle.module and rendered with isTemplate = true).
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "TailscaleKitPackage/lib"])
            ]
        ),
        .testTarget(
            name: "TailscreenTests",
            dependencies: [
                "Tailscreen",
                .product(name: "TailscreenAudio", package: "TailscreenProtocolPackage")
            ],
            path: "Tests/TailscreenTests",
            linkerSettings: [
                .unsafeFlags(["-L", "TailscaleKitPackage/lib"])
            ]
        )
    ]
)
