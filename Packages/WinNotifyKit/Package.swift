// swift-tools-version: 6.0
import PackageDescription

// WinNotifyKit — desktop notifications on Windows, via the Windows App SDK's
// `AppNotificationManager`. What `GNotifyKit` is on Linux and
// `UNUserNotificationCenter` is on macOS.
//
// The sharer surface that reaches somebody whose attention is on the thing they
// are sharing. During a share the app window is BEHIND the shared content, and
// raising it is itself visible to viewers — so every mid-share ask costs an
// interruption the people watching can see. "Require approval for new viewers"
// defaults on, which means an unattended sharer silently strands whoever tries
// to connect.
//
// **C, because swift-winui does not project this API.** Its Swift surface
// covers `Microsoft.UI.*` and `Microsoft.Windows.AppLifecycle` but not
// `Microsoft.Windows.AppNotifications`, so there is no `AppNotificationManager`
// to call from Swift. What it does ship is the C ABI header the shim is written
// against. Only the POSTING half needs it: a button press comes back through
// `ExtendedActivationKind.AppNotification`, which is projected, so there is no
// COM handler object here.
//
// Its own package, not part of `Apps/windows`, for the reason the other backend
// packages are: this way CI LINKS and RUNS it (`winnotify-probe`) rather than
// only typechecking it inside a WinUI app, and no WinUI ends up on the link
// line of anything that does not want it.
//
// Off Windows the shim stubs to failure, so `swift test --package-path
// Packages/WinNotifyKit` typechecks the wrapper and exercises the composition
// on Linux. Read the README's "What is proven" table before trusting the
// coverage: unlike the Linux gate, which runs a real dunst and presses a real
// button, nothing here posts a real toast. Nothing installs — the Windows App
// SDK is resolved at runtime.
let package = Package(
    name: "WinNotifyKit",
    products: [
        .library(name: "WinNotifyKit", targets: ["WinNotifyKit"]),
        // See the target comment: this exists to be LINKED, on Windows.
        .executable(name: "winnotify-probe", targets: ["winnotify-probe"]),
    ],
    dependencies: [
        .package(path: "../TailscreenKit")
    ],
    targets: [
        .target(
            name: "CWinNotify",
            path: "Sources/CWinNotify",
            linkerSettings: [
                // RoInitialize, RoGetActivationFactory and the HSTRING
                // functions. The Windows App SDK itself is NOT linked — the
                // runtime class is resolved by name at runtime, which is
                // exactly why a machine without it degrades instead of failing
                // to start.
                .linkedLibrary("runtimeobject", .when(platforms: [.windows])),
                // wsprintfA, for the error strings.
                .linkedLibrary("user32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "WinNotifyKit",
            dependencies: [
                "CWinNotify",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/WinNotifyKit"
        ),
        // The link check. A SwiftPM library target is compiled but never
        // LINKED, so a missing `runtimeobject.lib` symbol stays invisible until
        // the app links it — the failure mode WASAPIKit's missing GUIDs shipped
        // past its own CI step and hit eleven minutes later.
        //
        // On a real desktop it doubles as the manual gate this repository
        // cannot automate: `winnotify-probe --post` posts a toast with two
        // buttons and prints what the platform said, so a person can confirm it
        // appears, and `--check` reports registration and the
        // `AppNotificationSetting` without posting anything.
        .executableTarget(
            name: "winnotify-probe",
            dependencies: [
                "WinNotifyKit",
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
            ],
            path: "Sources/winnotify-probe"
        ),
        .testTarget(
            name: "WinNotifyKitTests",
            dependencies: ["WinNotifyKit"],
            path: "Tests/WinNotifyKitTests"
        ),
    ]
)
