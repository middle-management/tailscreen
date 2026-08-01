import Foundation

#if os(Windows)
    import WinSDK
#endif

/// Route the process's stdout/stderr somewhere a human can read.
///
/// The exe links as /SUBSYSTEM:WINDOWS (see Package.swift), so launching it
/// from Explorer, the Start menu, or an MSIX activation no longer materializes
/// a console window — the loader allocates one for console-subsystem binaries
/// before any of our code runs, which was the "app opens with a terminal"
/// jank. A GUI-subsystem process has no console at all, though, which would
/// make every print vanish — and a Swift fatalError's message with them, which
/// is exactly how the packaged app managed to die with no dying words. So, in
/// order:
///
///  1. If a parent console exists (launched from PowerShell/cmd), attach to it
///     and keep printing there. Output lands after the shell's prompt has
///     already returned — the classic GUI-app-with-attached-console
///     interleaving — but it is all there, exactly as before.
///  2. Otherwise redirect both streams to `%LOCALAPPDATA%\Tailscreen\logs\
///     tailscreen.log`, truncated per launch so the file is always "the last
///     run". For the MSIX-installed app, LOCALAPPDATA writes are virtualized,
///     so the file lands under `%LOCALAPPDATA%\Packages\<family>\LocalCache\
///     Local\Tailscreen\logs\`.
///
/// `freopen` reuses the stream's fd slot, so fd 2 stays fd 2 — the Swift
/// runtime's fatal-error report, which writes to stderr, follows the
/// redirection into the log. Both streams open in append mode against one
/// file: the CRT's "a" seeks to EOF on every write, so they interleave instead
/// of overwriting each other.
///
/// Off Windows this is a no-op — the GTK app keeps its terminal semantics.
enum ConsoleBridge {
    static func attachOrRedirect() {
        #if os(Windows)
            // ATTACH_PARENT_PROCESS. AttachConsole comes through the WinSDK
            // overlay as a plain Swift `Bool` on this toolchain — a first
            // attempt wrote `.boolValue` defensively and the compiler answered
            // "value of type 'Bool' has no member 'boolValue'".
            if AttachConsole(DWORD(bitPattern: -1)) {
                _ = freopen("CONOUT$", "w", stdout)
                _ = freopen("CONOUT$", "w", stderr)
                return
            }
            let base =
                ProcessInfo.processInfo.environment["LOCALAPPDATA"]
                ?? NSTemporaryDirectory()
            let dir = URL(fileURLWithPath: base)
                .appendingPathComponent("Tailscreen")
                .appendingPathComponent("logs")
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let log = dir.appendingPathComponent("tailscreen.log").path
            try? FileManager.default.removeItem(atPath: log)
            _ = freopen(log, "a", stdout)
            _ = freopen(log, "a", stderr)
            // Unbuffered: a crash must not eat the lines that explain it.
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
            print("tailscreen \(Date()) — no console attached, logging here")
        #endif
    }
}
