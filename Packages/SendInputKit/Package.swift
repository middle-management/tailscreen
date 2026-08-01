// swift-tools-version: 6.0
import PackageDescription

// SendInputKit — Win32 `SendInput` behind the portable `InputInjecting` seam.
// What `RemoteControlInjector` is on macOS.
//
// **Why a C shim at all.** `INPUT` carries an anonymous union of
// `MOUSEINPUT` / `KEYBDINPUT` / `HARDWAREINPUT`. Swift imports anonymous
// unions as a synthesized nested type whose spelling is a clang
// implementation detail, so building one from Swift works until a toolchain
// bump renames it. From C it is just a struct.
//
// The shim is a handful of Win32 calls; everything with a decision in it lives
// in Swift, and the pure arithmetic lives further out still —
// `WindowsPointerMapping` (normalized → virtual-desktop absolute, the scaling
// with three ways to be wrong) and `WindowsKeyCodeMapping` (HID usage → VK +
// extended bit) are both in TailscreenProtocol, where Linux CI tests them.
//
// It does NOT conform to `InputInjecting` here — that would mean depending on
// TailscreenSharer for one protocol. The conformance is an empty extension in
// TailscreenSharerWGC, the same shape `Apps/macOS/Sources/ScreenShareBackends.swift`
// uses.
//
// Nothing to install: `SendInput` is in user32, which ships with Windows.
let package = Package(
    name: "SendInputKit",
    products: [
        .library(name: "SendInputKit", targets: ["SendInputKit"]),
        // See the target comment: this exists to be LINKED.
        .executable(name: "sendinput-probe", targets: ["sendinput-probe"]),
    ],
    dependencies: [
        .package(path: "../TailscreenKit")
    ],
    targets: [
        .target(
            name: "CSendInput",
            path: "Sources/CSendInput",
            linkerSettings: [
                // SendInput, GetSystemMetrics, GetWindowRect.
                .linkedLibrary("user32", .when(platforms: [.windows])),
                // OpenProcessToken / GetTokenInformation, for the elevation
                // check behind `canDriveElevatedWindows`.
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "SendInputKit",
            dependencies: [
                "CSendInput",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/SendInputKit"
        ),
        // A link check. A SwiftPM library target is compiled but never LINKED,
        // so an undefined symbol stays invisible until something downstream
        // links it — which is exactly how WASAPIKit's missing GUIDs passed
        // their own CI step and failed eleven minutes later in the app.
        //
        // Deliberately NOT run in CI, unlike wasapi-probe's "no device" case:
        // running this moves a real cursor. It prints what it WOULD inject via
        // the test seam and injects nothing unless asked.
        .executableTarget(
            name: "sendinput-probe",
            dependencies: ["SendInputKit"],
            path: "Sources/sendinput-probe"
        ),
        .testTarget(
            name: "SendInputKitTests",
            dependencies: ["SendInputKit"],
            path: "Tests/SendInputKitTests"
        ),
    ]
)
