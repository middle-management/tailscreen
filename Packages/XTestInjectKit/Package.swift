// swift-tools-version: 6.0
import PackageDescription

// XTestInjectKit — X11's XTEST extension behind the portable `InputInjecting`
// seam. What `SendInputKit` is on Windows, `RemoteControlInjector` on macOS.
//
// C shim owns the DISPLAY CONNECTION and keymap lookup: `XTestFakeKeyEvent`
// takes a host-local *keycode*, but the wire carries HID usages.
// `X11KeyCodeMapping` (TailscreenProtocol, pure, Linux-CI-tested) does
// HID→keysym; only the final `XKeysymToKeycode` needs a live `Display *`.
//
// Does NOT conform to `InputInjecting` here (would need a TailscreenSharer
// dependency) — the conformance is an empty extension in
// TailscreenSharerLinux, same shape as Windows/macOS.
let package = Package(
    name: "XTestInjectKit",
    products: [
        .library(name: "XTestInjectKit", targets: ["XTestInjectKit"]),
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
                // xtst.pc emits only `-lXtst`; libX11 (XOpenDisplay etc.) isn't
                // pulled in transitively by any .pc here — name it explicitly.
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
        // Link check (see WASAPIKit's probe comment) plus `--audit-keysyms`,
        // which walks `X11KeyCodeMapping` through `XKeysymToString` to catch a
        // typo'd constant on an unassigned value. Needs no X server.
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
