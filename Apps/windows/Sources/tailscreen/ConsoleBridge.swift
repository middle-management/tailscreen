import Foundation

#if os(Windows)
import WinSDK
#endif

/// Route the process's stdout/stderr somewhere a human can read.
///
/// The exe links as /SUBSYSTEM:WINDOWS (see Package.swift), which has no
/// console at all — every `print` and a Swift `fatalError`'s message would
/// otherwise vanish. So, in order:
///
///  1. If a parent console exists (launched from PowerShell/cmd), attach to
///     it and print there.
///  2. Otherwise redirect both streams to `%LOCALAPPDATA%\Tailscreen\logs\
///     tailscreen.log`, truncated per launch. Virtualized under
///     `%LOCALAPPDATA%\Packages\<family>\LocalCache\...` for the MSIX-installed app.
///
/// `freopen` reuses the stream's fd slot, so fd 2 stays fd 2 and the fatal-
/// error report follows the redirection. Both streams open in append mode
/// against one file so they interleave instead of overwriting each other.
///
/// Off Windows this is a no-op — the GTK app keeps its terminal semantics.
enum ConsoleBridge {
    static func attachOrRedirect() {
        #if os(Windows)
        // ATTACH_PARENT_PROCESS. AttachConsole is a plain Swift `Bool` on
        // this toolchain, not an `.boolValue`-wrapped type.
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
