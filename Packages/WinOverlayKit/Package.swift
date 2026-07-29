// swift-tools-version: 6.0
import PackageDescription

// WinOverlayKit — the sharer's annotation overlay on Windows: a click-through,
// always-on-top, per-pixel-alpha window showing what viewers draw.
//
// macOS renders annotations with Core Graphics and the GTK viewer with OpenGL.
// Windows offers neither from here — GDI+ is C++ and drags in the MSVC standard
// library that already broke WASAPIKit, and Direct2D is a COM stack larger than
// the feature. What it does offer free is `UpdateLayeredWindow`, which
// composites a premultiplied BGRA bitmap. So the missing piece was never a
// drawing API; it was a rasterizer, and a rasterizer is arithmetic.
//
// Which is why almost nothing lives here. `AnnotationStore` (what should be on
// screen) and `AnnotationRasterizer` (how to draw it) are both in
// TailscreenProtocol, tested on Linux CI. This package owns window lifetime,
// which no test could check anyway.
//
// Nothing to install: user32 and gdi32 ship with Windows.
let package = Package(
    name: "WinOverlayKit",
    products: [
        .library(name: "WinOverlayKit", targets: ["WinOverlayKit"])
    ],
    dependencies: [
        .package(path: "../TailscreenKit")
    ],
    targets: [
        .target(
            name: "CWinOverlay",
            path: "Sources/CWinOverlay",
            linkerSettings: [
                // CreateWindowExW, UpdateLayeredWindow, SetWindowDisplayAffinity.
                .linkedLibrary("user32", .when(platforms: [.windows])),
                // CreateDIBSection, CreateCompatibleDC, SelectObject.
                .linkedLibrary("gdi32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "WinOverlayKit",
            dependencies: [
                "CWinOverlay",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/WinOverlayKit"
        ),
    ]
)
