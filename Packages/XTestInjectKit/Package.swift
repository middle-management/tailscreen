// swift-tools-version: 6.0
import PackageDescription

// XTestInjectKit — X11's XTEST extension behind the portable `InputInjecting`
// seam. What `SendInputKit` is on Windows and `RemoteControlInjector` is on
// macOS.
//
// **Why a C shim at all.** Not the same reason as `CSendInput` (which exists
// because `INPUT` carries an anonymous union Swift imports unstably). Nothing
// in Xlib is unrepresentable in Swift; what the shim owns is the DISPLAY
// CONNECTION and the keymap lookup. `XTestFakeKeyEvent` takes a *keycode*,
// which identifies a physical key on the machine running the X server and is
// meaningless off-host, while the wire carries HID usages. `X11KeyCodeMapping`
// turns those into *keysyms* — protocol-defined constants — and closing the
// last gap needs `XKeysymToKeycode`, which needs a live `Display *`.
//
// That split is what makes the interesting half testable: HID → keysym and the
// scroll/button arithmetic are pure and live in TailscreenProtocol, where
// Linux CI already runs them. What is left here is a gate, a queue, and four
// Xlib calls.
//
// It does NOT conform to `InputInjecting` here — that would mean depending on
// TailscreenSharer for one protocol. The conformance is an empty extension in
// TailscreenSharerLinux, the same shape Windows and macOS use.
//
// Install: apt `libxtst-dev` (which pulls libx11-dev).
let package = Package(
    name: "XTestInjectKit",
    products: [
        .library(name: "XTestInjectKit", targets: ["XTestInjectKit"]),
        // See the target comment: this exists to be LINKED.
        .executable(name: "xtest-probe", targets: ["xtest-probe"]),
    ],
    dependencies: [
        .package(path: "../TailscreenKit")
    ],
    targets: [
        .systemLibrary(
            name: "CXTestSys",
            path: "Sources/CXTestSys",
            pkgConfig: "xtst",
            providers: [.apt(["libxtst-dev"])]
        ),
        .target(
            name: "CXTestInject",
            dependencies: ["CXTestSys"],
            path: "Sources/CXTestInject",
            linkerSettings: [
                // xtst.pc emits only `-lXtst`; Xlib itself (XOpenDisplay,
                // XKeysymToKeycode, XFlush) comes from libX11, which no .pc in
                // this chain pulls in transitively. Same trap X11CaptureKit
                // documents for xcb-shm — a module-map `link` directive is not
                // propagated to a C target's link line, so name it here.
                .linkedLibrary("X11")
            ]
        ),
        .target(
            name: "XTestInjectKit",
            dependencies: [
                "CXTestInject",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/XTestInjectKit"
        ),
        // A link check, plus a keysym audit. A SwiftPM library target is
        // compiled but never LINKED, so an undefined symbol stays invisible
        // until something downstream links it — which is exactly how
        // WASAPIKit's missing GUIDs passed their own CI step and failed eleven
        // minutes later in the app.
        //
        // It earns a second job: `--audit-keysyms` walks every row of
        // `X11KeyCodeMapping` through `XKeysymToString` and fails on any that
        // Xlib's own tables do not name. That catches a typo'd constant that
        // landed on an unassigned value — the failure mode of a hand-written
        // table of 130 hex numbers, and one that is otherwise invisible until
        // a user presses that key. It needs no X server, so CI runs it.
        .executableTarget(
            name: "xtest-probe",
            dependencies: ["XTestInjectKit"],
            path: "Sources/xtest-probe"
        ),
        .testTarget(
            name: "XTestInjectKitTests",
            dependencies: ["XTestInjectKit"],
            path: "Tests/XTestInjectKitTests"
        ),
    ]
)
