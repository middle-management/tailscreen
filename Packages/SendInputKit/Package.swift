// swift-tools-version: 6.0
import PackageDescription

// SendInputKit — Win32 `SendInput` behind the portable `InputInjecting` seam.
// What `RemoteControlInjector` is on macOS.
//
// Why a C shim: `INPUT` carries an anonymous union of `MOUSEINPUT` /
// `KEYBDINPUT` / `HARDWAREINPUT`, and Swift imports anonymous unions as a
// synthesized nested type whose spelling is a clang implementation detail —
// stable in C, not in Swift across toolchain bumps.
//
// The shim is a handful of Win32 calls; decisions live in Swift, and the pure
// arithmetic lives further out in TailscreenProtocol (`WindowsPointerMapping`,
// `WindowsKeyCodeMapping`), where Linux CI tests it.
//
// Does NOT conform to `InputInjecting` here, to avoid depending on
// TailscreenSharer for one protocol — the conformance is an empty extension
// in TailscreenSharerWGC.
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
        // links it.
        //
        // Deliberately NOT run in CI: running this moves a real cursor. It
        // prints what it WOULD inject via the test seam and injects nothing
        // unless asked.
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
