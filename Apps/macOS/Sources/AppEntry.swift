import AppKit
import Foundation

/// Single entry point for both Tailscreen modes:
///   - Main: the SwiftUI app — docked main window + menubar sharer
///     tool (default).
///   - Capture helper: a headless child process that owns the
///     `SCStream` + `VideoEncoder` pipeline and feeds encoded access
///     units back to the main process over stdout. Selected by
///     `--capture-helper`.
///
/// The helper mode is what makes Stop Sharing reliably clear macOS's
/// screen-recording badge: the helper is a child process, and SIGTERM
/// → process death → replayd definitively releases the SCStream slot
/// every time, even when Apple's `stopCapture` completion handler
/// would have leaked. Each share spawns a fresh helper, so no
/// per-process state (replayd cool-downs, orphaned SCStreams) leaks
/// between sessions.
@main
enum TailscreenEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--capture-helper") {
            // -> Never; helper exits via exit().
            CaptureHelperMain.run()
        }
        if CommandLine.arguments.contains("--picker-helper") {
            // Short-lived UI subprocess that presents the macOS
            // native `SCContentSharingPicker`. Exits the moment the
            // user picks (or cancels) so the picker's XPC state
            // never lives in the long-running main process. -> Never.
            PickerHelperMain.run()
        }
        installMainProcessSignalHandlers()
        installMainMenuObservers()
        TailscreenApp.main()
    }

    /// SwiftUI's `MenuBarExtra` scene installs its own minimal mainMenu
    /// (Tailscreen / View / Window / Help) and re-asserts it across
    /// scene updates — installing ours from the popover's `.task` lost
    /// the race. Hooking the `NSApplication.didFinishLaunching` and
    /// `didBecomeActive` notifications runs `AppMenu.install` AFTER
    /// SwiftUI's setup, so File / Edit / View / Tools stay in the bar.
    /// `@NSApplicationDelegateAdaptor` would have been tidier, but it
    /// needs `@main` to be on the `App` type itself — and ours is on
    /// `TailscreenEntry` so we can route to the picker / capture
    /// helpers first.
    @MainActor
    private static func installMainMenuObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Tailscreen is a regular docked app (main window + Dock
                // icon + ⌘Tab). Assert `.regular` once, after SwiftUI's
                // own launch setup, so a MenuBarExtra-bearing app can't
                // drift to the `.accessory` default on any launch path.
                NSApp.setActivationPolicy(.regular)
                AppMenu.installIfNeeded()
                AppMenu.reinstall()
                // Must be set before anything posts, and Apple's guidance is
                // "before the app finishes launching". Without it every
                // notification posted while Tailscreen is frontmost is
                // silently suppressed by the system.
                TailscreenNotificationDelegate.install()
            }
        }
        nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppMenu.reinstall()
            }
        }
    }

    /// Trap SIGTERM (and SIGINT for direct-from-terminal launches)
    /// so that `test-local.sh` killing our pgid still gives the
    /// capture-helper child a chance to finish `SCStream.stopCapture`
    /// before we vanish. Without this the green recording badge in
    /// macOS Control Center hangs around after the test script exits
    /// because the helper gets SIGKILL'd mid-stop and replayd never
    /// sees the cleanup.
    private static func installMainProcessSignalHandlers() {
        // Standard pattern: ignore the default action (`SIG_IGN`) so
        // dispatch's signal source can take over without the kernel
        // also killing us synchronously.
        let signals: [Int32] = [SIGTERM, SIGINT]
        for sig in signals {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                // Handler runs on the main queue (per the source's
                // queue argument above), so we're already on the
                // main thread — `assumeIsolated` lets us reach the
                // MainActor-isolated `NSApplication.shared.terminate`
                // without a Task hop. Swift 6 strict concurrency
                // requires the explicit assertion.
                MainActor.assumeIsolated {
                    for src in Self.signalSources { src.cancel() }
                    Self.signalSources.removeAll()
                    NotificationCenter.default.post(
                        name: .tailscreenWillTerminateBySignal, object: nil)
                    // Hand control to AppKit so the SwiftUI App can
                    // run its normal shutdown path (which tears the
                    // helper child down via Process.terminate before
                    // returning).
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
    /// Posted from the main process's SIGTERM/SIGINT trap before we
    /// hand off to `NSApplication.terminate`. AppState observes it
    /// to fire a synchronous helper-process teardown so the helper
    /// gets a clean `Process.terminate` (= SIGTERM) before the main
    /// process exits.
    static let tailscreenWillTerminateBySignal = Notification.Name("tailscreen.willTerminateBySignal")
}
