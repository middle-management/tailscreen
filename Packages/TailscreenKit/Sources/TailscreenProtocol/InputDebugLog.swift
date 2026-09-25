import Foundation

/// `TAILSCREEN_DEBUG_INPUT=1` — instrumentation for the remote-control input
/// path, off by default. Input arriving seconds late looks identical to a
/// slow network from the outside, so this gives a live readout instead
/// (same shape as `TAILSCREEN_DEBUG_FEC` on the sharer's congestion arm).
///
/// Three call sites: viewer send time (`TailscaleScreenShareClient.sendInputEvent`),
/// sharer arrival gap (`TailscaleScreenShareServer`'s input gate), and sharer
/// injection wire-delta/line-count (`RemoteControlInjector.postScroll`, the
/// only place that distinguishes "no scroll arrived" from "arrived and moved
/// zero lines").
///
/// Writes to stderr rather than `TSLogger` so `test-local.sh`'s two processes
/// interleave into one merged log.
public enum InputDebugLog {
    /// Whether the instrumentation is on. Read once — this is a debugging
    /// switch for a whole run, not something to flip mid-session.
    public static let isEnabled =
        ProcessInfo.processInfo.environment["TAILSCREEN_DEBUG_INPUT"] == "1"

    /// Emit one line, prefixed so it greps out of a merged two-instance log.
    /// `@autoclosure` so a disabled run pays nothing for the interpolation.
    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[input] \(message())\n".utf8))
    }

    /// Format nanoseconds as milliseconds with one decimal, so a 4.8-second
    /// stall reads as `4812.3ms` rather than as a wall of digits.
    public static func ms(_ ns: UInt64) -> String {
        String(format: "%.1fms", Double(ns) / 1_000_000)
    }

    /// Rolling per-window statistics, so a live run gets one summary line a
    /// second instead of one per event at 90 Hz. Pure (caller supplies the
    /// clock) so windowing is unit tested (`InputDebugLogTests`). Not
    /// thread-safe; confine one instance to its own serial context.
    public struct Sampler: Sendable {
        /// How often a summary is emitted.
        public static let windowNs: UInt64 = 1_000_000_000

        private var windowStartNs: UInt64?
        /// Named `sampleCount`, not `count` — swiftlint's `empty_count` rule
        /// misreads a `count` comparison as a collection emptiness check.
        private var sampleCount = 0
        private var totalNs: UInt64 = 0
        private var maxNs: UInt64 = 0

        public init() {}

        /// Fold one measurement in. Returns a summary when the window closes,
        /// nil otherwise. Window opens on the FIRST sample, not at
        /// construction, so an idle grant doesn't dilute the first burst.
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
            // Ordering guard: a clock going backwards must not wrap `&-` into
            // an enormous elapsed and suppress every future summary.
            guard nowNs >= start, nowNs &- start >= Self.windowNs else { return nil }
            let mean = totalNs / UInt64(sampleCount)  // sampleCount >= 1 here
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
