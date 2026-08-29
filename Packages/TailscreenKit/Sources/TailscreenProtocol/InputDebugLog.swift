import Foundation

/// `TAILSCREEN_DEBUG_INPUT=1` — instrumentation for the remote-control input
/// path, off by default.
///
/// Exists because the two things that go wrong on this path are both
/// *invisible from the outside*: input that arrives seconds late looks
/// identical to a slow network, and a scroll that injects nothing looks
/// identical to a scroll that was never sent. Both were diagnosed by reading
/// code rather than by running the app, which is exactly the situation a live
/// readout fixes. The same shape as ``TAILSCREEN_DEBUG_FEC`` on the sharer's
/// congestion arm, and for the same reason.
///
/// Three call sites, one per suspect:
///
///   - **Viewer send** (`TailscaleScreenShareClient.sendInputEvent`) — how long
///     the framed write actually took. A multi-second number here means the
///     send is queued behind something on the connection, which is what
///     TailscaleKit patch 027 fixed; a small number means the delay is
///     elsewhere.
///   - **Sharer arrival** (`TailscaleScreenShareServer`'s input gate) — the gap
///     since the previous event. Steady small gaps are healthy; one long gap
///     followed by a burst is the same stall seen from the far end.
///   - **Sharer injection** (`RemoteControlInjector.postScroll`) — the wire
///     delta and the whole-line count it became, including when it banked to
///     nothing. This is the only place that distinguishes "no scroll arrived"
///     from "a scroll arrived and moved zero lines".
///
/// Writes to stderr rather than `TSLogger` so the two processes `test-local.sh`
/// spawns interleave into one merged log with everything else.
public enum InputDebugLog {
    /// Whether the instrumentation is on. Read once — this is a debugging
    /// switch for a whole run, not something to flip mid-session.
    public static let isEnabled =
        ProcessInfo.processInfo.environment["TAILSCREEN_DEBUG_INPUT"] == "1"

    /// Emit one line, prefixed so it greps out of a merged two-instance log.
    ///
    /// The message is an `@autoclosure` so a disabled run pays nothing for the
    /// string interpolation at the call site — these sit on a per-event path.
    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[input] \(message())\n".utf8))
    }

    /// Format nanoseconds as milliseconds with one decimal, so a 4.8-second
    /// stall reads as `4812.3ms` rather than as a wall of digits.
    public static func ms(_ ns: UInt64) -> String {
        String(format: "%.1fms", Double(ns) / 1_000_000)
    }

    /// Rolling per-window statistics over an event stream, so a live run gets
    /// one summary line a second instead of one line per event at 90 Hz.
    ///
    /// Pure — the caller supplies the clock — so the windowing is unit tested
    /// (`InputDebugLogTests`) rather than eyeballed against a real session.
    /// Not thread-safe; each call site confines one to its own serial context.
    public struct Sampler: Sendable {
        /// How often a summary is emitted.
        public static let windowNs: UInt64 = 1_000_000_000

        private var windowStartNs: UInt64?
        /// Named `sampleCount` rather than `count` on purpose: this is a
        /// scalar tally, and a property called `count` makes swiftlint's
        /// `empty_count` rule read every comparison against it as a collection
        /// emptiness check.
        private var sampleCount = 0
        private var totalNs: UInt64 = 0
        private var maxNs: UInt64 = 0

        public init() {}

        /// Fold one measurement in. Returns a summary string exactly when the
        /// window closes, and `nil` otherwise — so the caller's logging is a
        /// single `if let`.
        ///
        /// The window opens on the FIRST sample rather than at construction:
        /// a viewer that holds a grant for a minute before touching the mouse
        /// should not have its first burst averaged against that idle minute.
        public mutating func note(_ sampleNs: UInt64, nowNs: UInt64) -> String? {
            guard let start = windowStartNs else {
                windowStartNs = nowNs
                sampleCount = 1
                totalNs = sampleNs
                maxNs = sampleNs
                return nil
            }
            sampleCount += 1
            totalNs &+= sampleNs
            maxNs = max(maxNs, sampleNs)
            // `&-` and the ordering guard: a clock that appears to go backwards
            // must not wrap into an enormous elapsed and suppress every future
            // summary for the rest of the run.
            guard nowNs >= start, nowNs &- start >= Self.windowNs else { return nil }
            // At least two by construction: an open window means a previous
            // call set the tally to one, and this call incremented it. So the
            // divide needs no zero guard.
            let mean = totalNs / UInt64(sampleCount)
            let summary =
                "n=\(sampleCount) mean=\(InputDebugLog.ms(mean)) max=\(InputDebugLog.ms(maxNs))"
            windowStartNs = nil
            sampleCount = 0
            totalNs = 0
            maxNs = 0
            return summary
        }
    }
}
