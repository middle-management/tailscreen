// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cuple",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Cuple",
            targets: ["Cuple"]
        )
    ],
    dependencies: [
        // TailscaleKit local package
        .package(path: "./TailscaleKitPackage")
    ],
    targets: [
        .executableTarget(
            name: "Cuple",
            dependencies: [
                .product(name: "TailscaleKit", package: "TailscaleKitPackage")
            ],
            path: "Sources"
        )
    ]
)
