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
    targets: [
        .executableTarget(
            name: "Cuple",
            path: "Sources"
        )
    ]
)
