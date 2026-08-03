// swift-tools-version: 6.0
import PackageDescription

// X11HotkeyKit — a SYSTEM-WIDE hotkey on X11, via `XGrabKey`. What
// `RegisterHotKey` is on Windows (WinHotkeyKit) and Carbon's
// `RegisterEventHotKey` is on macOS (`Apps/macOS/Sources/GlobalHotkey.swift`).
//
// **Separate from XTestInjectKit** even though both are thin Xlib shims, and
// the split is not tidiness: that package WRITES input for the sharer's remote
// control, this one READS a chord for the local user. A viewer-only host wants
// this and must not link an injector it will never call — and the sharer's
// injector must not grow a keyboard grab, which is the one thing on X11 that
// can make the rest of the desktop stop receiving a key.
//
// The C part owns a `Display *` and `XKeysymToKeycode`, and nothing else.
// Every decision — keysym, modifier mask, the lock-key mask variants, what
// counts as an auto-repeat — is in TailscreenProtocol's `X11HotkeyMapping` /
// `GlobalHotkeyRepeatFilter`, where Linux CI tests it without an X server.
//
// Install: apt `libx11-dev`.
let package = Package(
    name: "X11HotkeyKit",
    products: [
        .library(name: "X11HotkeyKit", targets: ["X11HotkeyKit"]),
        // See the target comment: this exists to be LINKED, and to be the one
        // gate that presses a real key against a real server.
        .executable(name: "x11-hotkey-probe", targets: ["x11-hotkey-probe"]),
    ],
    dependencies: [
        .package(path: "../TailscreenKit"),
        // Probe only: the live check needs to SYNTHESIZE the chord, which is
        // the injection direction and therefore XTEST's. The library itself
        // does not depend on it.
        .package(path: "../XTestInjectKit"),
    ],
    targets: [
        .systemLibrary(
            name: "CX11HotkeySys",
            path: "Sources/CX11HotkeySys",
            pkgConfig: "x11",
            providers: [.apt(["libx11-dev"])]
        ),
        .target(
            name: "CX11Hotkey",
            dependencies: ["CX11HotkeySys"],
            path: "Sources/CX11Hotkey"
        ),
        .target(
            name: "X11HotkeyKit",
            dependencies: [
                "CX11Hotkey",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/X11HotkeyKit"
        ),
        // The link check AND the live gate. A SwiftPM library target is
        // compiled but never LINKED, so a missing `-lX11` stays invisible
        // until something downstream links it — the failure mode WASAPIKit's
        // missing GUIDs shipped past its own CI step.
        //
        // Its second job is the one no unit test can do: grab the chord on a
        // real server, synthesize the keystroke through XTEST, and assert the
        // callback fired. Everything up to the Xlib call is covered by the
        // portable mapping tests; this covers the call, the lock-mask
        // variants, the XSync-based failure detection, and the fact that a
        // grabbed key is delivered at all.
        .executableTarget(
            name: "x11-hotkey-probe",
            dependencies: [
                "X11HotkeyKit",
                .product(name: "XTestInjectKit", package: "XTestInjectKit"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/x11-hotkey-probe"
        ),
        .testTarget(
            name: "X11HotkeyKitTests",
            dependencies: ["X11HotkeyKit"],
            path: "Tests/X11HotkeyKitTests"
        ),
    ]
)
