// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TailscaleKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v16)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "TailscaleKit",
            targets: ["TailscaleKit"]
        ),
    ],
    targets: [
        // TailscaleKit Swift wrapper
        .target(
            name: "TailscaleKit",
            dependencies: ["libtailscale"],
            path: "Sources/TailscaleKit",
            linkerSettings: [
                .linkedLibrary("tailscale", .when(platforms: [.macOS, .iOS]))
            ]
        ),

        // C library system target
        .systemLibrary(
            name: "libtailscale",
            path: "Modules/libtailscale",
            pkgConfig: "libtailscale"
        ),

        // Tests
        .testTarget(
            name: "TailscaleKitTests",
            dependencies: ["TailscaleKit"]
        ),
    ]
)
