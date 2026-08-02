// swift-tools-version: 6.0
import PackageDescription

// tailscreen (Linux) — the native desktop app: a full sharer AND viewer, the
// Linux sibling of Apps/macOS and Apps/windows. The executable is plain
// `tailscreen`; the package keeps a platform-qualified name because package
// names are build-graph identity, not what users run.
//
// A SEPARATE package from Packages/TailscreenLinuxBackends on purpose: it pulls
// in swift-cross-ui + GTK4, which the backends' `linux-viewer` CI job neither
// needs nor should pay for. Video is a downstream `GtkVideoView` (a
// swift-cross-ui `View` hosting a `GtkGLArea` with an OpenGL YUV→RGB
// renderer); chrome is declarative swift-cross-ui, shared with the Windows app
// via Packages/TailscreenHubUI. See docs/linux-viewer-gtk-plan.md.
//
// It reuses TailscreenLinuxBackends' `TailscreenViewerCore` (FFmpeg decoder +
// ALSA sink) and `TailscreenSharerLinux` (X11 capture + libavcodec encode),
// plus `TailscreenViewerTsnet` (the shared tsnet transport). Pulling Tsnet
// brings TailscaleKit (→ libtailscale.a), so a live run needs the c-archive.
//
// swift-cross-ui is pinned to an exact revision for reproducibility — its `View`
// protocol is young and can reshape across versions, and our only coupling to it
// is the small `GtkVideoView`.
let package = Package(
    name: "tailscreen-linux",
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui",
            revision: "199a85614e3b2346aa10736b12f969af14a1f1ea"),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscreenLinuxBackends"),
        .package(path: "../../Packages/TailscaleKit"),
        // X11 root capture — used by the overlay self-test to read the screen
        // back. Already in the graph transitively via TailscreenLinuxBackends;
        // declared here because this package imports it directly.
        .package(path: "../../Packages/X11CaptureKit"),
        // The hub's look — header, screen rows, cards, placards — shared with
        // the Windows app. It used to live in this executable as
        // `ViewerChrome.swift`; it moved out when a second swift-cross-ui app
        // needed the same design system and copying it would have guaranteed
        // the two drifted apart.
        .package(path: "../../Packages/TailscreenHubUI"),
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
        // GTK4's headers for the C targets below. See the module map for why
        // this is declared here rather than reused from swift-cross-ui.
        .systemLibrary(
            name: "CGtk4Sys",
            path: "Sources/CGtk4Sys",
            pkgConfig: "gtk4-x11",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        // The sharer's annotation overlay: a click-through, always-on-top
        // window showing viewers' strokes on the sharer's own screen. C
        // because the two things it does that GTK4 will not — override-redirect
        // placement and stacking — are raw X11, and because the interesting
        // halves (`ReceivedAnnotations`, `AnnotationRasterizer`) already live
        // in the portable tier where Linux CI tests them.
        .target(
            name: "CGtkOverlay",
            dependencies: ["CGtk4Sys"]
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
                .product(name: "TailscreenViewerCore", package: "TailscreenLinuxBackends"),
            ]
        ),
        .executableTarget(
            name: "tailscreen",
            dependencies: [
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                .product(name: "TailscaleKit", package: "TailscaleKit"),
                .product(name: "TailscreenSharerLinux", package: "TailscreenLinuxBackends"),
                "TailscreenViewerGtk",
                "CGtkOverlay",
                // X11 root capture, for the overlay self-test: it draws a known
                // pattern and then reads the screen back to prove the pixels
                // actually landed. Already in the graph via TailscreenSharerLinux;
                // named explicitly because this target imports it directly.
                .product(name: "X11CaptureKit", package: "X11CaptureKit"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // FFmpeg decoder + the shared tsnet transport, reused from the
                // Packages/TailscreenLinuxBackends library package. A path
                // dependency's identity is its DIRECTORY basename, not its
                // `name:` — which is why `package:` below reads
                // "TailscreenLinuxBackends" and not "tailscreen-linux".
                .product(name: "TailscreenViewerCore", package: "TailscreenLinuxBackends"),
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit"),
                .product(name: "TailscreenHubUI", package: "TailscreenHubUI"),
            ],
            linkerSettings: [
                // Resolve libtailscale.a for the tsnet transport. Belt and
                // braces: libtailscale.pc anchors its own -L to ${pcfiledir},
                // so pkg-config supplies the real path and this flag only
                // matters when the build runs from this directory.
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
    ]
)
