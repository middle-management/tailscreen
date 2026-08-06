import Foundation
import TailscaleKit

/// The one `print`-backed `LogSink` behind this package's per-file loggers.
///
/// Seven files (five here in TailscreenTransport, plus
/// `TailscaleScreenShareServer` in TailscreenSharer, which depends on this
/// module) used to end with an identical `private struct TSLogger` differing
/// only in the `[Prefix]` tag — and two of them re-implemented the same
/// "Listening for " filter. This is that struct, once, with the prefix as
/// data. `package` visibility on purpose: the sink is package plumbing, not
/// API, and the macOS app's own per-file `TSLogger`s are a different,
/// AppKit-adjacent convention this deliberately does not reach.
///
/// The one sink in this package that is NOT this type is
/// `TsnetTransport.StderrLogger` (TailscreenViewerTsnet), which writes to
/// stderr **by design** — the viewer executables keep stdout clean for the
/// data path; see its comment.
package struct PrintLogSink: LogSink {
    /// Handed to the Go backend when this sink drives node bring-up. Every
    /// per-file logger this replaces left it nil (no Go-internal log file).
    package let logFileHandle: Int32?
    private let prefix: String
    private let dropListeningNoise: Bool

    /// - Parameters:
    ///   - prefix: the `[Prefix]` tag in front of every line — each call
    ///     site keeps the exact string its private logger printed.
    ///   - dropListeningNoise: swallow tsnet's once-per-poll "Listening
    ///     for …" lines, as the control-listener and sharer loggers always
    ///     have.
    package init(
        prefix: String,
        dropListeningNoise: Bool = false,
        logFileHandle: Int32? = nil
    ) {
        self.prefix = prefix
        self.dropListeningNoise = dropListeningNoise
        self.logFileHandle = logFileHandle
    }

    package func log(_ message: String) {
        if dropListeningNoise, message.hasPrefix("Listening for ") { return }
        print("[\(prefix)] \(message)")
    }
}
