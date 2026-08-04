// swift-tools-version: 6.0
import PackageDescription

// GNotifyKit — desktop notifications on Linux, over the freedesktop D-Bus
// interface. What `UNUserNotificationCenter` is on macOS and
// `AppNotificationManager` is on Windows.
//
// The sharer surface that reaches somebody whose attention is on the thing they
// are sharing. During a share, the app window is BEHIND the shared content and
// raising it is itself visible to viewers — so every mid-share ask costs an
// interruption the people watching can see. "Require approval for new viewers"
// defaults on, which means an unattended sharer silently strands whoever tries
// to connect. A notification is the only surface that reaches them.
//
// Its own package, not part of `Apps/linux`, for the reason the other backend
// packages are: this way Linux CI links and RUNS it (`gnotify-probe`) against a
// real notification daemon, rather than only typechecking it inside a GTK app.
// It also keeps GLib off the link line of anything that does not want it.
//
// Every decision — what to say, when, how to dedupe, when to withdraw — is in
// `TailscreenProtocol`'s `SharerNotice`. This package is delivery, and knows
// nothing about viewers or shares.
//
// Install: apt `libglib2.0-dev` (gio-2.0 + glib-2.0 + gobject-2.0 via
// pkg-config). Runtime needs a notification daemon; there is no fallback and
// none is wanted — see the README.
let package = Package(
    name: "GNotifyKit",
    products: [
        .library(name: "GNotifyKit", targets: ["GNotifyKit"]),
        // See the target comment: this exists to be LINKED, and to be the one
        // gate that posts to a real daemon and hears a real button.
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
        // until something downstream links it — the failure mode WASAPIKit's
        // missing GUIDs shipped past its own CI step.
        //
        // Its second job is the one no unit test can do: post to a real
        // notification daemon, ask it what it can render, press a real button
        // and assert the signal came back. The `Notify` argument signature in
        // particular has eight fields and two containers, and getting it wrong
        // is a D-Bus error at call time that nothing else in this repo would
        // ever produce.
        .executableTarget(
            name: "gnotify-probe",
            dependencies: ["GNotifyKit", "CGNotify"],
            path: "Sources/gnotify-probe"
        ),
    ]
)
