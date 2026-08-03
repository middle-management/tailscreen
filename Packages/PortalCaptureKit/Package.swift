// swift-tools-version: 6.0
import PackageDescription

// PortalCaptureKit — screen capture through `org.freedesktop.portal.ScreenCast`
// and PipeWire, for the Linux sharer's `CaptureEncoding` backend.
//
// This is the Wayland-capable sibling of X11CaptureKit. X11 capture landed
// first because it is the one capture path that runs headlessly under Xvfb;
// the portal cannot, ever, because it is built around a consent dialog a
// person has to click. See README.md for exactly what this package's CI leg
// does and does not prove.
//
// Wrapped the way X11CaptureKit wraps libxcb: systemLibrary targets over the
// two system libraries, a C shim that owns their boilerplate, and a
// Foundation-only Swift wrapper.
//
// Deliberately dependency-free — no TailscreenKit, exactly like X11CaptureKit
// and WGCCaptureKit. It hands back BGRA and does NO colour conversion; the
// portable `BGRAToI420` in TailscreenProtocol owns that, and the
// `CaptureEncoding` conformance that will consume this (in
// TailscreenLinuxBackends) is where the two meet — the same split
// WGCCaptureKit → TailscreenSharerWGC already uses on Windows.
let package = Package(
    name: "PortalCaptureKit",
    products: [
        .library(name: "PortalCaptureKit", targets: ["PortalCaptureKit"]),
        .executable(name: "portal-probe", targets: ["portal-probe"]),
    ],
    targets: [
        .systemLibrary(
            name: "CDBusSys",
            path: "Sources/CDBusSys",
            pkgConfig: "dbus-1",
            providers: [.apt(["libdbus-1-dev"])]
        ),
        .systemLibrary(
            name: "CPipeWireSys",
            path: "Sources/CPipeWireSys",
            pkgConfig: "libpipewire-0.3",
            providers: [.apt(["libpipewire-0.3-dev"])]
        ),
        // The shim. Two halves that never call each other: the D-Bus
        // negotiation (which ends with a PipeWire fd and a node id) and the
        // PipeWire stream (which starts from them). Keeping them separate is
        // what lets the negotiation half be tested against a fake portal with
        // no PipeWire daemon anywhere in the picture.
        .target(
            name: "CPortalCapture",
            dependencies: ["CDBusSys", "CPipeWireSys"],
            path: "Sources/CPortalCapture"
        ),
        // A fake `org.freedesktop.portal.ScreenCast` service. NOT part of the
        // library product — it is test scaffolding, and a capture library that
        // shipped a way to impersonate the consent authority would be a poor
        // thing to have on disk. Only `portal-probe` and the tests link it.
        .target(
            name: "CPortalFakeBus",
            dependencies: ["CDBusSys"],
            path: "Sources/CPortalFakeBus"
        ),
        // A synthetic PipeWire producer. Also NOT part of the library product,
        // and for a second reason beyond CPortalFakeBus's: it is the only way
        // anything here can be run without a compositor, so it is what turns
        // the PipeWire half from "compiles and links" into "delivers the pixels
        // we expect". See its header for the three things it still cannot
        // cover.
        .target(
            name: "CPipeWireFakeSource",
            dependencies: ["CPipeWireSys"],
            path: "Sources/CPipeWireFakeSource"
        ),
        .target(
            name: "PortalCaptureKit",
            dependencies: ["CPortalCapture"],
            path: "Sources/PortalCaptureKit"
        ),
        // The link check, plus the two things a library target cannot do:
        // drive a real portal, and drive a fake one. See its main.swift.
        .executableTarget(
            name: "portal-probe",
            dependencies: ["PortalCaptureKit", "CPortalFakeBus", "CPipeWireFakeSource"],
            path: "Sources/portal-probe"
        ),
        .testTarget(
            name: "PortalCaptureKitTests",
            dependencies: ["PortalCaptureKit"],
            path: "Tests/PortalCaptureKitTests"
        ),
    ]
)
