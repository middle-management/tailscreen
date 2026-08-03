// swift-tools-version: 6.0
import PackageDescription

// WinHotkeyKit — a SYSTEM-WIDE hotkey on Windows, via `RegisterHotKey`. What
// X11HotkeyKit is on Linux and `Apps/macOS/Sources/GlobalHotkey.swift` is on
// macOS.
//
// C only because the mechanism is: a message pump on a thread this owns,
// because `WM_HOTKEY` is a THREAD message and XAML's own pump would remove it
// and dispatch it nowhere. Every decision — which virtual key, which
// `fsModifiers`, `MOD_NOREPEAT` — lives in TailscreenProtocol's
// `WindowsHotkeyMapping`, where Linux CI tests it.
//
// Off Windows the shim stubs to failure, so `swift test --package-path
// Packages/WinHotkeyKit` typechecks the wrapper and exercises the decisions on
// Linux. Read the test file's header before trusting the coverage: there is no
// `RegisterHotKey` here and nothing stands in for one, exactly as WASAPIKit
// documents for its own Linux leg. Nothing installs; `RegisterHotKey` ships
// with Windows.
let package = Package(
    name: "WinHotkeyKit",
    products: [
        .library(name: "WinHotkeyKit", targets: ["WinHotkeyKit"]),
        // See the target comment: this exists to be LINKED, on Windows.
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
        // The link check. A SwiftPM library target is compiled but never
        // LINKED, so a missing `user32.lib` symbol stays invisible until the
        // app links it — the failure mode WASAPIKit's missing GUIDs shipped
        // past its own CI step and hit eleven minutes later.
        //
        // On a real desktop it doubles as the manual gate this repository
        // cannot automate: `winhotkey-probe --hold` takes the chord and prints
        // each press, so a person can confirm it fires from another app.
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
