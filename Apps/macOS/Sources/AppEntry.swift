import AppKit
import Foundation

/// Single entry point for both Tailscreen modes:
///   - Main: the SwiftUI app — docked main window + menubar sharer tool.
///   - Capture helper (`--capture-helper`): a headless child owning the
///     `SCStream`+`VideoEncoder` pipeline, feeding AUs back over stdout.
///
/// The helper is what makes Stop Sharing reliably clear macOS's
/// screen-recording badge: SIGTERM → process death → replayd releases the
/// SCStream slot every time, even when `stopCapture`'s completion handler
/// would have leaked. A fresh helper per share means no state leaks between
/// sessions.
@main
enum TailscreenEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--capture-helper") {
            // -> Never; helper exits via exit().
            CaptureHelperMain.run()
        }
        if CommandLine.arguments.contains("--picker-helper") {
            // Presents the native `SCContentSharingPicker` and exits, so its
            // XPC state never lives in the long-running main process. -> Never.
            PickerHelperMain.run()
        }
        installMainProcessSignalHandlers()
        // After the two helper routes (which never return), so a helper
        // never opens a second session record nobody asked for.
        AppDiagnostics.start()
        installLaunchNotificationObservers()
        TailscreenApp.main()
    }

    /// Launch-time AppKit setup that has to run AFTER SwiftUI's own scene
    /// bring-up. `@NSApplicationDelegateAdaptor` would be tidier, but it
    /// needs `@main` on the `App` type itself, and ours is on
    /// `TailscreenEntry` so it can route to the picker/capture helpers first.
    @MainActor
    private static func installLaunchNotificationObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Assert `.regular` once, after SwiftUI's own launch setup,
                // so a MenuBarExtra-bearing app can't drift to `.accessory`.
                NSApp.setActivationPolicy(.regular)
                // Must be set before anything posts (Apple's guidance:
                // "before the app finishes launching"), or notifications
                // posted while frontmost are silently suppressed.
                TailscreenNotificationDelegate.install()
                // CI screenshots a UI-preview launch where nobody clicks the
                // Dock icon; activate so the capture shows our window.
                if AppState.isUIPreview {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    /// Trap SIGTERM/SIGINT so `test-local.sh` killing our pgid still gives
    /// the capture-helper a chance to finish `SCStream.stopCapture` — else
    /// it's SIGKILL'd mid-stop and the recording badge hangs around.
    private static func installMainProcessSignalHandlers() {
        // Ignore the default action so dispatch's signal source can take
        // over without the kernel also killing us synchronously.
        let signals: [Int32] = [SIGTERM, SIGINT]
        for sig in signals {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                // Runs on the main queue, so `assumeIsolated` reaches
                // MainActor-isolated `terminate` without a Task hop.
                MainActor.assumeIsolated {
                    for src in Self.signalSources { src.cancel() }
                    Self.signalSources.removeAll()
                    NotificationCenter.default.post(
                        name: .tailscreenWillTerminateBySignal, object: nil)
                    // Hand off to AppKit's normal shutdown path, which tears
                    // the helper down via Process.terminate.
                    NSApplication.shared.terminate(nil)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
}

extension Notification.Name {
    /// Posted before handing off to `NSApplication.terminate`. AppState
    /// observes it to synchronously tear the helper down (clean
    /// Process.terminate) before the main process exits.
    static let tailscreenWillTerminateBySignal = Notification.Name("tailscreen.willTerminateBySignal")
}
