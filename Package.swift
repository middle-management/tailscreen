// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cuple",
    platforms: [
        .macOS(.v15)
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
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-L", "TailscaleKitPackage/lib"])
            ]
        ),
        .testTarget(
            name: "CupleTests",
            dependencies: ["Cuple"],
            path: "Tests/CupleTests",
            linkerSettings: [
                .unsafeFlags(["-L", "TailscaleKitPackage/lib"])
            ]
        )
    ]
)
