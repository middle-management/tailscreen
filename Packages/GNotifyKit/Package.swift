// swift-tools-version: 6.0
import PackageDescription

// GNotifyKit — desktop notifications on Linux, over the freedesktop D-Bus
// interface. What `UNUserNotificationCenter` is on macOS and
// `AppNotificationManager` is on Windows.
//
// Its own package, not part of `Apps/linux`, so Linux CI links and RUNS it
// (`gnotify-probe`) against a real notification daemon, and keeps GLib off
// the link line of anything that doesn't want it.
//
// Every decision — what to say, when, how to dedupe, when to withdraw — is in
// `TailscreenProtocol`'s `SharerNotice`. This package is delivery only.
//
// Install: apt `libglib2.0-dev` (gio-2.0 + glib-2.0 + gobject-2.0 via
// pkg-config). Runtime needs a notification daemon; there is no fallback.
let package = Package(
    name: "GNotifyKit",
    products: [
        .library(name: "GNotifyKit", targets: ["GNotifyKit"]),
        // Exists to be LINKED, and to be the one gate that posts to a real
        // daemon and hears a real button.
        .executable(name: "gnotify-probe", targets: ["gnotify-probe"]),
    ],
    targets: [
        .systemLibrary(
            name: "CGNotifySys",
            path: "Sources/CGNotifySys",
            pkgConfig: "gio-2.0",
            providers: [.apt(["libglib2.0-dev"])]
        ),
        .target(
            name: "CGNotify",
            dependencies: ["CGNotifySys"],
            path: "Sources/CGNotify"
        ),
        .target(
            name: "GNotifyKit",
            dependencies: ["CGNotify"],
            path: "Sources/GNotifyKit"
        ),
        // The link check AND the live gate. A SwiftPM library target is
        // compiled but never LINKED, so a missing `-lgio-2.0` stays invisible
        // until something downstream links it. Its second job is the one no
        // unit test can do: post to a real daemon, ask what it can render,
        // press a real button, assert the signal came back.
        .executableTarget(
            name: "gnotify-probe",
            dependencies: ["GNotifyKit", "CGNotify"],
            path: "Sources/gnotify-probe"
        ),
    ]
)
