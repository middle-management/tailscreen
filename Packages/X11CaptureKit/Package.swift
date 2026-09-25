// swift-tools-version: 6.0
import PackageDescription

// X11CaptureKit — X11 screen capture for the Linux sharer's `CaptureEncoding`
// backend. C shim (`CX11Capture`) owns XCB + SysV shared-memory boilerplate
// and BGRA→I420 conversion, over system libxcb.
//
// X11 rather than the ScreenCast portal: the portal needs a session bus,
// compositor and consent dialog, so it can never run in CI; X11 capture runs
// headlessly under Xvfb. Both sit behind the same `CaptureEncoding` seam.
let package = Package(
    name: "X11CaptureKit",
    products: [
        .library(name: "X11CaptureKit", targets: ["X11CaptureKit"])
    ],
    targets: [
        .systemLibrary(
            name: "CXCB",
            path: "Sources/CXCB",
            pkgConfig: "xcb",
            providers: [.apt(["libxcb1-dev", "libxcb-shm0-dev"])]
        ),
        .target(
            name: "CX11Capture",
            dependencies: ["CXCB"],
            path: "Sources/CX11Capture",
            // xcb-shm's .pc is separate from xcb's and never pulled in
            // transitively; SwiftPM doesn't propagate module-map `link`
            // directives to a C target's link line either, so name it here.
            linkerSettings: [.linkedLibrary("xcb-shm")]
        ),
        .target(
            name: "X11CaptureKit",
            dependencies: ["CX11Capture"],
            path: "Sources/X11CaptureKit"
        ),
        .testTarget(
            name: "X11CaptureKitTests",
            dependencies: ["X11CaptureKit"],
            path: "Tests/X11CaptureKitTests"
        )
    ]
)
