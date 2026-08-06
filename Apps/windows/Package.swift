// swift-tools-version: 6.0
import PackageDescription

// tailscreen (Windows) — the native Windows desktop app. The executable is
// plain `tailscreen.exe`; the package keeps a platform-qualified name because
// package names are build-graph identity, not what users run.
//
// A SEPARATE package from Apps/linux for the same reason that one is
// separate from Packages/TailscreenLinuxBackends: it pulls a UI toolchain (the Windows App SDK, via
// swift-cross-ui's WinUIBackend) that no other job should pay for. The GTK app
// additionally carries `CGtkVideo`, a GTK-linked C target that cannot build
// here at all.
//
// Built up in stages (plans/viewer-windows-plan.md, W2–W4) because nothing Swift
// in this repo had ever been compiled for Windows: this stage is UI-only, so a
// failure lands in a small surface rather than somewhere in the union of
// swift-cross-ui, tsnet, FFmpeg and D3D. Transport and video follow once the
// chrome is proven to build and run.
//
// swift-cross-ui is pinned to the same exact revision as the GTK app — its
// `View` protocol is young and can reshape across versions, and two apps
// disagreeing about it would be a needless source of drift.
let package = Package(
    name: "tailscreen-windows",
    products: [
        // See the target comment: this is a diagnostic, not a shipped app.
        .executable(name: "tsnet-probe", targets: ["tsnet-probe"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui",
            revision: "199a85614e3b2346aa10736b12f969af14a1f1ea"),
        // Declared directly because W4's video surface imports WinUI types
        // (`Image`, `WriteableBitmap`) to satisfy `WinUIElementRepresentable`'s
        // `WinUIElementType`. swift-cross-ui depends on this too but does not
        // re-export it, and SwiftPM resolves one version for the graph — so the
        // requirement is written to match theirs exactly rather than pinning a
        // revision that could contradict it.
        .package(
            url: "https://github.com/moreSwift/swift-winui",
            .upToNextMinor(from: "0.2.1")),
        .package(path: "../../Packages/TailscreenKit"),
        .package(path: "../../Packages/TailscreenVideoFFmpeg"),
        .package(path: "../../Packages/WASAPIKit"),
        .package(path: "../../Packages/TailscreenSharerWGC"),
        .package(path: "../../Packages/WGCCaptureKit"),
        // ⌃⌥M held system-wide (RegisterHotKey), so a sharer who has
        // alt-tabbed into the thing they are showing can still mute
        // themselves. Its shim stubs out off Windows, so the `linux-app` job
        // typechecks the wiring here.
        .package(path: "../../Packages/WinHotkeyKit"),
        // Desktop notifications (AppNotificationManager), so a sharer whose
        // attention is on the thing they are showing is still reachable when
        // somebody is stuck at the approval gate. Same story as the hotkey
        // above: its shim stubs out off Windows, so the `linux-app` job
        // typechecks the wiring here.
        .package(path: "../../Packages/WinNotifyKit"),
        // The hub's look, shared with the GTK viewer. Extracted from that app
        // rather than reinvented here: swift-cross-ui is a SwiftUI subset, so
        // this chrome is hand-built from primitives, and building it twice
        // would have produced two apps that agreed on day one and never again.
        .package(path: "../../Packages/TailscreenHubUI"),
        // The string catalog, shared with the macOS and GTK apps: `L(_:)` plus
        // the `.lproj`s behind it. Same argument as the chrome above — a
        // string translated once should be translated for all three apps.
        .package(path: "../../Packages/TailscreenL10n"),
    ],
    targets: [
        // D3D11 YUV->RGB for the video surface — the sibling of the GTK app's
        // `CGtkVideo`, and the reason `WinUIVideoView` no longer converts colour
        // on the CPU. C++ because D3D11 is COM; the header is `extern "C"` so
        // Swift imports it as a plain C module.
        //
        // The Windows SDK libraries are named here rather than assumed: a
        // `systemLibrary` target would need a module map for headers that are
        // already on the SDK include path, and `d3dcompiler` is a link-time
        // dependency the runtime DLL satisfies (it ships with the staged
        // self-contained runtime). `microsoft.ui.xaml.media.dxinterop.h` comes
        // from the swift-winui dependency's bundled nuget headers.
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
                // DefaultBackend resolves to WinUIBackend on Windows (see
                // swift-cross-ui's Package.swift), so the app doesn't name a
                // backend and can still be built on a dev machine that isn't
                // Windows for a quick syntax check.
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                // WinUIElementRepresentable lives in the backend module, and
                // the WinUI types it is generic over come from swift-winui.
                //
                // Conditioned on Windows so the edge disappears elsewhere —
                // which is what makes `swift build --product tailscreen`
                // work on Linux, and therefore what lets Linux CI typecheck
                // this app instead of a Windows runner being the only machine
                // that can. (swift-winui's `CWinAppSDK` includes
                // <wtypesbase.h>; without the condition it is pulled in and
                // fails to compile before any of our code is reached.)
                // `WinUIVideoView` carries the matching `#if os(Windows)`.
                .product(
                    name: "WinUIBackend", package: "swift-cross-ui",
                    condition: .when(platforms: [.windows])),
                .product(
                    name: "WinUI", package: "swift-winui",
                    condition: .when(platforms: [.windows])),
                .target(name: "CWinVideo", condition: .when(platforms: [.windows])),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                // libavcodec behind the portable VideoDecoding seam — the same
                // decoder the Linux viewer uses, which is why it is a shared
                // package rather than anything Windows-specific.
                .product(name: "TailscreenVideoFFmpeg", package: "TailscreenVideoFFmpeg"),
                .product(name: "TailscreenViewer", package: "TailscreenKit"),
                // The tsnet transport: node bring-up, interactive login and
                // peer discovery. Shared with the Linux/GTK viewer — it lives
                // in TailscreenKit precisely so consuming it here doesn't also
                // drag in FFmpeg, ALSA and X11.
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit"),
                // WASAPI behind the portable `AudioSink` seam — what ALSAKit is
                // to the Linux viewer. No system package to install: WASAPI is
                // part of Windows.
                .product(name: "WASAPIKit", package: "WASAPIKit"),
                // The Opus codec, the microphone seam and the RTP voice
                // uplink/downlink — the voice path both endpoints share.
                .product(name: "TailscreenAudio", package: "TailscreenKit"),
                // Sharing. A package of its own so it carries no WinUI and
                // Linux CI can typecheck it — which covers the capture loop AND
                // `WindowsShareSession`, whose off-the-main-actor discipline is
                // exactly what a Windows-only build would let through unread.
                // WGCCaptureKit is named directly because the app holds the
                // picked `WGC.CaptureItem` between the picker and the share.
                .product(name: "TailscreenSharerWGC", package: "TailscreenSharerWGC"),
                .product(name: "WGCCaptureKit", package: "WGCCaptureKit"),
                // The system-wide mute chord (RegisterHotKey + its pump
                // thread). Stubbed off Windows, so this edge stays on the
                // Linux typecheck path rather than behind a platform
                // condition.
                .product(name: "WinHotkeyKit", package: "WinHotkeyKit"),
                // Desktop notifications. Stubbed off Windows for the same
                // reason, which is what keeps `SharerNotifications.swift` on
                // the Linux typecheck path instead of behind an `#if`.
                .product(name: "WinNotifyKit", package: "WinNotifyKit"),
                .product(name: "TailscreenHubUI", package: "TailscreenHubUI"),
                .product(name: "TailscreenL10n", package: "TailscreenL10n"),
            ],
            // libtailscale.a is a link-time input, so the flag belongs on this
            // executable rather than on the library targets that merely compile
            // against the header. Relative, never absolute — see CLAUDE.md.
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"]),
                // GUI subsystem: SwiftPM's default is a console-subsystem PE,
                // so the loader materialized a terminal window before any of
                // our code ran — including for the MSIX-installed app. The
                // ENTRY override keeps Swift's ordinary `main` path (a bare
                // /SUBSYSTEM:WINDOWS makes the linker expect WinMain); the CRT
                // init it runs is the same one that walks .CRT$XCU, so the Go
                // runtime start (patch 026) is unaffected. ConsoleBridge
                // reattaches or redirects the now-consoleless stdio.
                // tsnet-probe deliberately stays a console binary.
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows])),
            ]
        ),
        // A console tsnet bring-up, with no WinUI, no Windows App SDK, no COM
        // apartment and no swift-cross-ui run loop — same libtailscale.a, same
        // Swift runtime, same machine. It exists to split "the Go archive
        // hangs on Windows" from "the app's environment hangs it", which the
        // GUI app cannot distinguish from the inside.
        //
        // Lives here rather than in TailscreenKit because it needs the same
        // relative `-L` for libtailscale.a that the app has, and because the
        // Windows job already builds this package.
        .executableTarget(
            name: "tsnet-probe",
            dependencies: [
                .product(name: "TailscreenViewerTsnet", package: "TailscreenKit")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])
            ]
        )
    ]
)
