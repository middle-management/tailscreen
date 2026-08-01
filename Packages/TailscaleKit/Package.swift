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
            dependencies: ["libtailscale", "CGoRuntimeInit"],
            path: "Sources/TailscaleKit"
        ),

        // Starts the Go runtime inside libtailscale.a on Windows, where
        // nothing else does — Go asks for it through a `.ctors` section that
        // only MinGW's startup walks, and Swift links with MSVC's. See
        // ts_go_runtime.c; it is an empty function everywhere else.
        //
        // A dependency of TailscaleKit rather than of the apps, because
        // TailscaleNode.init is where the call belongs: put it in a host and
        // every future host has to remember it, and forgetting means a
        // freeze with no error.
        .target(
            name: "CGoRuntimeInit",
            path: "Sources/CGoRuntimeInit"
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
