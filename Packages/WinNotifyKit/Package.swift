// swift-tools-version: 6.0
import PackageDescription

// WinNotifyKit — desktop notifications via the Windows App SDK's
// `AppNotificationManager`. What `GNotifyKit` is on Linux, `UNUserNotification
// Center` on macOS. During a share the app window is behind the shared
// content, so a mid-share raise is itself visible to viewers — notifications
// are the surface that reaches an unattended sharer.
//
// **C, because swift-winui doesn't project `Microsoft.Windows.AppNotifications`**
// — only the C ABI header. Only the posting half needs it; a button press
// comes back through the already-projected `ExtendedActivationKind
// .AppNotification`, so there's no COM handler object here.
//
// Off Windows the shim stubs to failure — typechecks + exercises composition
// on Linux, but nothing here posts a real toast (see README's "What is
// proven" table). Windows App SDK is resolved at runtime, nothing to install.
let package = Package(
    name: "WinNotifyKit",
    products: [
        .library(name: "WinNotifyKit", targets: ["WinNotifyKit"]),
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
                // RoInitialize, RoGetActivationFactory, HSTRING. Windows App
                // SDK itself is not linked — resolved by name at runtime,
                // so a machine without it degrades instead of failing to start.
                .linkedLibrary("runtimeobject", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),  // wsprintfA
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
        // Link check (see WASAPIKit's probe comment). `--post` posts a toast
        // with two buttons as a manual gate; `--check` reports registration
        // and `AppNotificationSetting` without posting anything.
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
