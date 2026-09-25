import Foundation
import TailscaleKit
import TailscreenProtocol

/// The one `print`-backed `LogSink` behind this package's per-file loggers —
/// replaces what used to be seven near-identical `private struct TSLogger`s
/// differing only in the `[Prefix]` tag. `package` visibility: sink plumbing,
/// not API.
///
/// `TsnetTransport.StderrLogger` (TailscreenViewerTsnet) is the one sink NOT
/// this type — it writes to stderr by design, keeping viewer stdout clean
/// for the data path.
package struct PrintLogSink: LogSink {
    /// Handed to the Go backend when this sink drives node bring-up. Every
    /// per-file logger this replaces left it nil (no Go-internal log file).
    package let logFileHandle: Int32?
    private let prefix: String
    private let dropListeningNoise: Bool
    private let capturesDiagnostics: Bool

    /// - Parameters:
    ///   - prefix: the `[Prefix]` tag in front of every line — each call
    ///     site keeps the exact string its private logger printed.
    ///   - dropListeningNoise: swallow tsnet's once-per-poll "Listening
    ///     for …" lines, as the control-listener and sharer loggers always
    ///     have.
    ///   - capturesDiagnostics: whether these lines are teed into the
    ///     diagnostics recorder. Default true; `TailscaleAuth` passes **false**
    ///     because it logs the signed-in account's display name, which
    ///     redaction can't strip (nothing distinguishes an account name from
    ///     a device name in free text) — auth state is recorded as
    ///     structured events instead.
    package init(
        prefix: String,
        dropListeningNoise: Bool = false,
        logFileHandle: Int32? = nil,
        capturesDiagnostics: Bool = true
    ) {
        self.prefix = prefix
        self.dropListeningNoise = dropListeningNoise
        self.logFileHandle = logFileHandle
        self.capturesDiagnostics = capturesDiagnostics
    }

    package func log(_ message: String) {
        if dropListeningNoise, message.hasPrefix("Listening for ") { return }
        print("[\(prefix)] \(message)")
        // Tee into the process recorder, if a host installed one — see
        // `DiagnosticsCenter.captureLog`.
        if capturesDiagnostics {
            DiagnosticsCenter.shared.captureLog(source: prefix, message: message)
        }
    }
}
