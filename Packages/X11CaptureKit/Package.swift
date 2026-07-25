// swift-tools-version: 6.0
import PackageDescription

// X11CaptureKit — X11 screen capture for the Linux sharer's `CaptureEncoding`
// backend.
//
// Wrapped the way ALSAKit wraps libasound and FFmpegKit wraps libavcodec: a
// C shim (`CX11Capture`) that owns the XCB + SysV shared-memory boilerplate
// and the per-pixel BGRA→I420 conversion, plus a Foundation-only Swift
// wrapper. Builds against system libxcb (apt `libxcb1-dev libxcb-shm0-dev`).
//
// Why X11 and not the ScreenCast portal first: the portal is the right
// production path on Wayland, but it needs a session bus, a compositor, and a
// user consent dialog, so it can never run in CI. X11 capture runs headlessly
// under Xvfb, which buys a capture backend the test suite can actually
// exercise. Both sit behind the same `CaptureEncoding` seam, so adding the
// portal backend later changes no caller.
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
            // `xcb` arrives via CXCB's pkg-config, but the SHM extension is a
            // separate library whose own .pc emits only `-lxcb-shm` and which
            // pkg-config therefore never pulls in transitively. A module-map
            // `link` directive isn't enough — SwiftPM doesn't propagate those
            // to a C target's link line — so name it explicitly.
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
