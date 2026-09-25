import Foundation

/// Cadence gate in front of `transport.summary`: turns per-packet counters
/// into one rollup event per window instead of logging every `receiveRTP`
/// call. Owns only the *when*; callers (viewer `tick`, sharer adaptive
/// sweep) supply the clock via ``windowClosed(nowNs:)`` and fill in their own
/// fields. See `.claude/rules/diagnostics.md`.
public struct DiagnosticsTransportSampler: Sendable, Equatable {

    /// Matches the sharer's adaptive-bitrate window, so both sides' summaries
    /// cover the same interval.
    public static let defaultWindowNs: UInt64 = 5_000_000_000

    /// How long a window is, in nanoseconds.
    public let windowNs: UInt64

    /// Clock reading the open window began at; nil before the first call.
    private var windowStartNs: UInt64?

    public init(windowNs: UInt64 = Self.defaultWindowNs) {
        // Clamp rather than trap: zero would fire on every tick.
        self.windowNs = max(1, windowNs)
    }

    /// Advance the clock. Returns the closed window's length (`window_ms`
    /// for the caller's summary) or nil if none closed.
    ///
    /// The first call only opens the window (a summary at admission would be
    /// all zeros). A clock reading earlier than the window start re-opens it
    /// there without firing, since the monotonic clock can't step backwards
    /// but this type can't assume its caller used one.
    public mutating func windowClosed(nowNs: UInt64) -> UInt64? {
        guard let start = windowStartNs else {
            windowStartNs = nowNs
            return nil
        }
        guard nowNs >= start else {
            windowStartNs = nowNs
            return nil
        }
        let elapsed = nowNs - start
        guard elapsed >= windowNs else { return nil }
        windowStartNs = nowNs
        return elapsed
    }

    /// Forget the open window, for a session ending and restarting on the
    /// same object.
    public mutating func reset() {
        windowStartNs = nil
    }
}
