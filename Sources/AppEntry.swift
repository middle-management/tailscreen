import Foundation

/// Single entry point for both Tailscreen modes:
///   - Main: the menubar SwiftUI app (default).
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
    static func main() {
        if CommandLine.arguments.contains("--capture-helper") {
            CaptureHelperMain.run()
            return  // unreachable; helper exits via exit()
        }
        TailscreenApp.main()
    }
}
