// swift-tools-version: 6.0
import PackageDescription

// PortalCaptureKit — screen capture through `org.freedesktop.portal.ScreenCast`
// and PipeWire, for the Linux sharer's `CaptureEncoding` backend.
//
// The Wayland-capable sibling of X11CaptureKit. X11 landed first because it
// runs headlessly under Xvfb; the portal cannot, ever, since it's built
// around a consent dialog a person has to click. See README.md for exactly
// what this package's CI leg does and does not prove.
//
// Wrapped like X11CaptureKit wraps libxcb: systemLibrary targets over the two
// system libraries, a C shim, a Foundation-only Swift wrapper.
//
// Deliberately dependency-free, like X11CaptureKit and WGCCaptureKit. Hands
// back BGRA with NO colour conversion — the portable `BGRAToI420` in
// TailscreenProtocol owns that, the same split WGCCaptureKit uses on Windows.
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
        // negotiation (ends with a PipeWire fd + node id) and the PipeWire
        // stream (starts from them) — separate, so negotiation can be tested
        // against a fake portal with no PipeWire daemon in the picture.
        .target(
            name: "CPortalCapture",
            dependencies: ["CDBusSys", "CPipeWireSys"],
            path: "Sources/CPortalCapture"
        ),
        // A fake `org.freedesktop.portal.ScreenCast` service. NOT part of the
        // library product — test scaffolding only, so only `portal-probe` and
        // the tests link it.
        .target(
            name: "CPortalFakeBus",
            dependencies: ["CDBusSys"],
            path: "Sources/CPortalFakeBus"
        ),
        // A synthetic PipeWire producer, also not shipped — the only way to
        // run this without a compositor. See its header for what it still
        // cannot cover.
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
