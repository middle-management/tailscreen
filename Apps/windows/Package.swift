// swift-tools-version: 6.0
import PackageDescription

// tailscreen (Windows) — the native Windows desktop app. The executable is
// plain `tailscreen.exe`; the package keeps a platform-qualified name because
// package names are build-graph identity, not what users run.
//
// A separate package from Apps/linux so this doesn't pull in the Windows App
// SDK (via swift-cross-ui's WinUIBackend) for jobs that don't need it; the GTK
// app also carries `CGtkVideo`, a GTK-linked C target that can't build here.
//
// swift-cross-ui is pinned to the same exact revision as the GTK app — its
// `View` protocol is young enough to reshape across versions.
let package = Package(
    name: "tailscreen-windows",
    products: [
        // See the target comments: both are diagnostics, not shipped apps.
        .executable(name: "tsnet-probe", targets: ["tsnet-probe"]),
        .executable(name: "winvideo-selftest", targets: ["winvideo-selftest"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui",
            revision: "199a85614e3b2346aa10736b12f969af14a1f1ea"),
        // The video surface imports WinUI types (`Image`, `WriteableBitmap`)
        // directly. swift-cross-ui depends on this too but doesn't re-export
        // it, and SwiftPM resolves one version for the graph, so the
        // requirement matches theirs rather than pinning a revision that
        // could contradict it.
        .package(
            url: "https://github.com/moreSwift/swift-winui",
            .upToNextMinor(from: "0.2.1")),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscreenVideoFFmpeg"),
        .package(path: "../../Packages/WASAPIKit"),
        .package(path: "../../Packages/TailscreenSharerWGC"),
        .package(path: "../../Packages/WGCCaptureKit"),
        // ⌃⌥M held system-wide (RegisterHotKey). Its shim stubs out off
        // Windows, so the `linux-app` job typechecks the wiring here.
        .package(path: "../../Packages/WinHotkeyKit"),
        // Desktop notifications (AppNotificationManager); same stub story as the hotkey above.
        .package(path: "../../Packages/WinNotifyKit"),
        // The hub's look, shared with the GTK viewer (swift-cross-ui is a
        // SwiftUI subset, so this chrome is hand-built from primitives).
        .package(path: "../../Packages/TailscreenHubUI"),
        // The string catalog, shared with the macOS and GTK apps.
        .package(path: "../../Packages/TailscreenL10n"),
    ],
    targets: [
        // D3D11 YUV->RGB for the video surface — the sibling of the GTK app's
        // `CGtkVideo`. C++ because D3D11 is COM; the header is `extern "C"`
        // so Swift imports it as a plain C module. The Windows SDK libraries
        // are named here rather than assumed via `systemLibrary`, since their
        // headers are already on the SDK include path.
        .target(
            name: "CWinVideo",
            linkerSettings: [
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                .linkedLibrary("d3dcompiler", .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "tailscreen",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                // DefaultBackend resolves to WinUIBackend on Windows, so the
                // app doesn't name a backend and can still build on non-Windows
                // for a quick syntax check.
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                // Conditioned on Windows so `swift build --product tailscreen`
                // still works on Linux — swift-winui's `CWinAppSDK` includes
                // <wtypesbase.h>, which fails to compile without the
                // condition. `WinUIVideoView` carries the matching `#if
                // os(Windows)`.
                .product(
                    name: "WinUIBackend", package: "swift-cross-ui",
                    condition: .when(platforms: [.windows])),
                // The clipboard binding (`Clipboard`, `DataPackage`) the share
                // card's Copy buttons go through (WindowsClipboard.swift).
                .product(
                    name: "UWP", package: "swift-winui",
                    condition: .when(platforms: [.windows])),
                .product(
                    name: "WinUI", package: "swift-winui",
                    condition: .when(platforms: [.windows])),
                .target(name: "CWinVideo", condition: .when(platforms: [.windows])),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // libavcodec behind the portable VideoDecoding seam — the same decoder the Linux viewer uses.
                .product(name: "TailscreenVideoFFmpeg", package: "TailscreenVideoFFmpeg"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                // tsnet transport, shared with the Linux/GTK viewer so consuming
                // it doesn't also drag in FFmpeg, ALSA and X11.
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit"),
                // The ask-to-share coordinator, shared with the GTK engine and macOS.
                .product(name: "TailscreenSharer", package: "TailscreenKit"),
                // WASAPI behind the portable `AudioSink` seam — what ALSAKit is to the Linux viewer.
                .product(name: "WASAPIKit", package: "WASAPIKit"),
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
                // Sharing. A package of its own so it carries no WinUI and
                // Linux CI can typecheck the capture loop and
                // `WindowsShareSession`'s off-the-main-actor discipline.
                .product(name: "TailscreenSharerWGC", package: "TailscreenSharerWGC"),
                .product(name: "WGCCaptureKit", package: "WGCCaptureKit"),
                // Stubbed off Windows, so `linux-app` typechecks the wiring here.
                .product(name: "WinHotkeyKit", package: "WinHotkeyKit"),
                .product(name: "WinNotifyKit", package: "WinNotifyKit"),
                .product(name: "TailscreenHubUI", package: "TailscreenHubUI"),
                .product(name: "TailscreenL10n", package: "TailscreenL10n"),
            ],
            // libtailscale.a is a link-time input, so the flag belongs on this
            // executable rather than the library targets that merely compile
            // against the header. Relative, never absolute — see CLAUDE.md.
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"]),
                // GUI subsystem: SwiftPM's default is console-subsystem, which
                // materializes a terminal window before our code runs. The
                // ENTRY override keeps Swift's ordinary `main` path (a bare
                // /SUBSYSTEM:WINDOWS expects WinMain) without disturbing the
                // Go runtime's CRT init. ConsoleBridge reattaches or redirects
                // the now-consoleless stdio. tsnet-probe stays a console binary.
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows])),
            ]
        ),
        // A console tsnet bring-up, with no WinUI, no Windows App SDK, no COM
        // apartment and no swift-cross-ui run loop. Exists to split "the Go
        // archive hangs on Windows" from "the app's environment hangs it,"
        // which the GUI app can't distinguish from the inside. Lives here
        // (not TailscreenKit) for the same relative `-L` the app needs.
        .executableTarget(
            name: "tsnet-probe",
            dependencies: [
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        ),
        // The headless render self-test: ColorBars through CWinVideo's D3D11
        // shader, pixels read back, no XAML involved. Carries no WinUI, so it
        // runs on a runner with no desktop session and no package identity.
        // No libtailscale `-L`: unlike the probe, this touches no transport.
        .executableTarget(
            name: "winvideo-selftest",
            dependencies: [
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                .target(name: "CWinVideo", condition: .when(platforms: [.windows])),
            ]
        )
    ]
)
