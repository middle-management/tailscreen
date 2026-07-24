// swift-tools-version: 6.0
import PackageDescription

// tailscreen-viewer-gtk — the native GTK desktop viewer (Linux/Windows).
//
// A SEPARATE package from Apps/linux on purpose: it pulls in swift-cross-ui +
// GTK4, which the Apps/linux core `linux-viewer` CI job neither needs nor should
// pay for. Video is a downstream `GtkVideoView` (a swift-cross-ui `View` hosting
// a `GtkGLArea` with an OpenGL YUV→RGB renderer); chrome is declarative
// swift-cross-ui. See docs/linux-viewer-gtk-plan.md.
//
// It reuses Apps/linux's `TailscreenViewerCore` (FFmpeg decoder + ALSA sink)
// and `TailscreenViewerTsnet` (the shared tsnet transport). Pulling Tsnet brings
// TailscaleKit (→ libtailscale.a), so a live run needs the built c-archive.
//
// swift-cross-ui is pinned to an exact revision for reproducibility — its `View`
// protocol is young and can reshape across versions, and our only coupling to it
// is the small `GtkVideoView`.
let package = Package(
    name: "tailscreen-viewer-gtk",
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui",
            revision: "199a85614e3b2346aa10736b12f969af14a1f1ea"),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../linux"),
    ],
    targets: [
        // OpenGL YUV→RGB renderer for the GLArea. C so it can call GL (via
        // epoxy) directly; the Swift side just hands it plane pointers. Links
        // gtk-4 for the one forward-declared queue-render entry point.
        .target(
            name: "CGtkVideo",
            linkerSettings: [
                .linkedLibrary("epoxy"),
                .linkedLibrary("gtk-4"),
                .linkedLibrary("glib-2.0"),
            ]
        ),
        // GtkVideoView + the video sink + frame store: the downstream video
        // surface, reusable by the live app and the render self-test.
        .target(
            name: "TailscreenViewerGtk",
            dependencies: [
                "CGtkVideo",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "GtkBackend", package: "swift-cross-ui"),
                .product(name: "Gtk", package: "swift-cross-ui"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // The pure GTK→InputEvent capture mapping (`ViewerInputMapping`)
                // lives in Core so it's unit-tested by the linux-viewer job;
                // GtkVideoView feeds it raw GDK integers. Already linked by the
                // executable target, so no new system dependency.
                .product(name: "TailscreenViewerCore", package: "linux"),
            ]
        ),
        .executableTarget(
            name: "tailscreen-viewer-gtk",
            dependencies: [
                "TailscreenViewerGtk",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // FFmpeg decoder + the shared tsnet transport, reused from the
                // Apps/linux core library package. The path dependency's
                // identity is its directory name, `linux`.
                .product(name: "TailscreenViewerCore", package: "linux"),
                .product(name: "TailscreenViewerTsnet", package: "linux"),
            ],
            linkerSettings: [
                // Resolve libtailscale.a for the tsnet transport (same relative
                // path the core package uses).
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
    ]
)
