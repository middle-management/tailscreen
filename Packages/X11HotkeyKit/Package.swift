// swift-tools-version: 6.0
import PackageDescription

// X11HotkeyKit — system-wide hotkey on X11 via `XGrabKey`. What
// `RegisterHotKey` is on Windows and Carbon's hotkey API is on macOS.
//
// Separate from XTestInjectKit though both are thin Xlib shims: that package
// WRITES input for remote control, this one READS a chord locally — a
// viewer-only host must not link an injector it never calls, and the
// injector must not grow a keyboard grab (can freeze the rest of X11 input).
//
// C part owns only `Display *` + `XKeysymToKeycode`; every decision (keysym,
// modifier mask, lock-key variants, auto-repeat) is in TailscreenProtocol's
// `X11HotkeyMapping`/`GlobalHotkeyRepeatFilter`, tested on Linux CI without an X server.
let package = Package(
    name: "X11HotkeyKit",
    products: [
        .library(name: "X11HotkeyKit", targets: ["X11HotkeyKit"]),
        .executable(name: "x11-hotkey-probe", targets: ["x11-hotkey-probe"]),
    ],
    dependencies: [
        .package(path: "../TailscreenKit"),
        // Probe only: the live check synthesizes the chord via XTEST. The
        // library itself does not depend on it.
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
        // Link check (see WASAPIKit's probe comment) plus the live gate:
        // grabs the chord on a real server, synthesizes the keystroke via
        // XTEST, asserts the callback fired — covers the Xlib call, lock-mask
        // variants and XSync-based failure detection no unit test can reach.
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
