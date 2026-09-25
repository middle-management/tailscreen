// swift-tools-version: 6.0
import PackageDescription

// WinHotkeyKit — system-wide hotkey on Windows via `RegisterHotKey`. What
// X11HotkeyKit is on Linux and Carbon's hotkey API is on macOS.
//
// C shim owns a message pump on its own thread: `WM_HOTKEY` is a THREAD
// message, so XAML's own pump would swallow it. Decisions (virtual key,
// `fsModifiers`, `MOD_NOREPEAT`) live in TailscreenProtocol's
// `WindowsHotkeyMapping`, tested on Linux CI.
//
// Off Windows the shim stubs to failure — typechecks + exercises the
// decisions on Linux, but nothing here actually calls `RegisterHotKey`.
let package = Package(
    name: "WinHotkeyKit",
    products: [
        .library(name: "WinHotkeyKit", targets: ["WinHotkeyKit"]),
        .executable(name: "winhotkey-probe", targets: ["winhotkey-probe"]),
    ],
    dependencies: [
        .package(path: "../TailscreenKit")
    ],
    targets: [
        .target(
            name: "CWinHotkey",
            path: "Sources/CWinHotkey"
        ),
        .target(
            name: "WinHotkeyKit",
            dependencies: [
                "CWinHotkey",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/WinHotkeyKit"
        ),
        // Link check (see WASAPIKit's probe comment); on a real desktop
        // `--hold` takes the chord and prints each press as a manual gate.
        .executableTarget(
            name: "winhotkey-probe",
            dependencies: [
                "WinHotkeyKit",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/winhotkey-probe"
        ),
        .testTarget(
            name: "WinHotkeyKitTests",
            dependencies: ["WinHotkeyKit"],
            path: "Tests/WinHotkeyKitTests"
        ),
    ]
)
