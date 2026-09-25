// swift-tools-version: 6.0
import PackageDescription

// Package name is build-graph identity, not the executable name (`tailscreen`).
//
// Separate package from Packages/TailscreenLinuxBackends so GTK4 +
// swift-cross-ui don't leak into the backends' `linux-viewer` CI job. See
// plans/linux-viewer-gtk-plan.md.
//
// swift-cross-ui is pinned to an exact revision: its `View` protocol is young
// and can reshape across versions.
let package = Package(
    name: "tailscreen-linux",
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui",
            revision: "199a85614e3b2346aa10736b12f969af14a1f1ea"),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscreenLinuxBackends"),
        .package(path: "../../Packages/TailscaleKit"),
        // Used directly by the overlay self-test to read the screen back
        // (already transitive via TailscreenLinuxBackends).
        .package(path: "../../Packages/X11CaptureKit"),
        // Portal ScreenCast backend: Wayland capture (and future
        // single-window capture).
        .package(path: "../../Packages/TailscreenSharerPortal"),
        .package(path: "../../Packages/PortalCaptureKit"),
        // Drives real X11 events at the armed overlay for the overlay INPUT
        // self-test, proving the input region actually flipped.
        .package(path: "../../Packages/XTestInjectKit"),
        // System-wide mute hotkey (XGrabKey). Separate from XTestInjectKit
        // (writes remote-control input) so a viewer-only run needn't link it.
        .package(path: "../../Packages/X11HotkeyKit"),
        // Desktop notifications — reaches the sharer even when this window
        // isn't focused.
        .package(path: "../../Packages/GNotifyKit"),
        // Shared hub UI (header, rows, cards) with the Windows app, kept as
        // one package so the two don't drift apart.
        .package(path: "../../Packages/TailscreenHubUI"),
        // Shared string catalog with macOS/Windows — one translation serves
        // all three.
        .package(path: "../../Packages/TailscreenL10n"),
    ],
    targets: [
        // OpenGL YUV→RGB renderer for the GLArea. C so it can call GL (via
        // epoxy) directly; Swift side only hands it plane pointers.
        .target(
            name: "CGtkVideo",
            linkerSettings: [
                .linkedLibrary("epoxy"),
                .linkedLibrary("gtk-4"),
                .linkedLibrary("glib-2.0"),
            ]
        ),
        // GTK4 headers for the C targets below; see the module map for why
        // not reused from swift-cross-ui.
        .systemLibrary(
            name: "CGtk4Sys",
            path: "Sources/CGtk4Sys",
            pkgConfig: "gtk4-x11",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        // The sharer's click-through, always-on-top annotation overlay. C
        // because override-redirect placement/stacking are raw X11, which
        // GTK4 won't do; the testable logic (`ReceivedAnnotations`,
        // `AnnotationRasterizer`) lives in the portable tier.
        .target(
            name: "CGtkOverlay",
            dependencies: ["CGtk4Sys"]
        ),
        .target(
            name: "TailscreenViewerGtk",
            dependencies: [
                "CGtkVideo",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "GtkBackend", package: "swift-cross-ui"),
                .product(name: "Gtk", package: "swift-cross-ui"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // `ViewerInputMapping` (GTK→InputEvent) lives in Core so it's
                // unit-tested by linux-viewer; this target only feeds it raw
                // GDK integers.
                .product(name: "TailscreenViewerCore", package: "TailscreenLinuxBackends"),
                // Publishes user-facing placard/status strings, so it reads
                // the L10n catalog directly.
                .product(name: "TailscreenL10n", package: "TailscreenL10n"),
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
                // GDK clipboard for the share card's Copy buttons;
                // swift-cross-ui doesn't expose it. See Clipboard.swift.
                "CGtk4Sys",
                // Used by the overlay self-test to read the screen back and
                // verify pixels landed (already transitive via
                // TailscreenSharerLinux).
                .product(name: "X11CaptureKit", package: "X11CaptureKit"),
                .product(name: "TailscreenSharerPortal", package: "TailscreenSharerPortal"),
                // The app owns the PortalSession (negotiates consent once,
                // held for the share's life).
                .product(name: "PortalCaptureKit", package: "PortalCaptureKit"),
                .product(name: "XTestInjectKit", package: "XTestInjectKit"),
                // ⌃⌥M system-wide mute, reachable even when alt-tabbed into
                // the shared app.
                .product(name: "X11HotkeyKit", package: "X11HotkeyKit"),
                .product(name: "GNotifyKit", package: "GNotifyKit"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // A path dependency's identity is its DIRECTORY basename, not
                // `name:` — hence `package: "TailscreenLinuxBackends"` below,
                // not "tailscreen-linux".
                .product(name: "TailscreenViewerCore", package: "TailscreenLinuxBackends"),
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit"),
                // Idle TCP/7447 listener answering an incoming "please share"
                // ask; separate from the share's own listener since asks
                // arrive when this machine isn't sharing.
                .product(name: "TailscreenTransport", package: "TailscreenKit"),
                .product(name: "TailscreenHubUI", package: "TailscreenHubUI"),
                .product(name: "TailscreenL10n", package: "TailscreenL10n"),
            ],
            linkerSettings: [
                // Belt-and-braces: libtailscale.pc already anchors -L to
                // ${pcfiledir} via pkg-config; this only matters if built
                // from outside that context.
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
    ]
)
