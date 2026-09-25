// swift-tools-version: 6.0
import PackageDescription

// WinOverlayKit — sharer's annotation overlay on Windows: a click-through,
// always-on-top, per-pixel-alpha window showing what viewers draw, via
// `UpdateLayeredWindow` (premultiplied BGRA) — avoids GDI+/Direct2D, which
// would drag in the MSVC STL that broke WASAPIKit.
//
// `ReceivedAnnotations`/`AnnotationRasterizer` live in TailscreenProtocol
// (tested on Linux CI); this package owns only window lifetime.
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
                .linkedLibrary("user32", .when(platforms: [.windows])),  // CreateWindowExW, UpdateLayeredWindow
                .linkedLibrary("gdi32", .when(platforms: [.windows])),  // CreateDIBSection, CreateCompatibleDC
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
