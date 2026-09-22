import Foundation

/// The cadence gate in front of `transport.summary`.
///
/// The rule for the recorder is *decisions, not packets*: `receiveRTP` runs
/// hundreds of times a second and a record of every call would push the
/// handshake out of the ring in under a minute. But the packet path is also
/// where the picture's quality is decided — loss, NACKs, FEC recoveries, RTT,
/// PLIs — and a bundle that carries none of it cannot tell a clean session
/// from one whose receiver reports quietly stopped arriving. The compromise
/// is a **per-window rollup**: both ends already keep the counters, and one
/// event per window turns them into a row a reader can diff against the next.
///
/// This type owns only the *when*. Both hosts call ``windowClosed(nowNs:)``
/// from a loop they already run on a clock (the viewer's `tick`, the sharer's
/// adaptive sweep), and record a summary when it returns a window length.
/// The fields are each side's own: the viewer's come from
/// `ViewerSession.Diagnostics`, the sharer's from its per-viewer state.
///
/// Driven on an explicit clock rather than a timer, the `AnnotationStore`
/// discipline: a suite advances `nowNs` and asserts exactly which ticks fire,
/// and a host that already ticks on a cadence pays nothing extra.
public struct DiagnosticsTransportSampler: Sendable, Equatable {

    /// Five seconds. Matches the sharer's adaptive-bitrate window, so one
    /// sharer summary per viewer lines up with one viewer summary — the same
    /// window read from both ends is the whole point of the pair. At this
    /// rate a single viewer fills the recorder's 4096-event ring in roughly
    /// five and a half hours, which is the budget the ring was sized for.
    public static let defaultWindowNs: UInt64 = 5_000_000_000

    /// How long a window is, in nanoseconds.
    public let windowNs: UInt64

    /// Clock reading the open window began at; nil before the first call.
    private var windowStartNs: UInt64?

    public init(windowNs: UInt64 = Self.defaultWindowNs) {
        // A zero window would fire on every tick, which is the per-packet
        // firehose this type exists to prevent. Clamp rather than trap.
        self.windowNs = max(1, windowNs)
    }

    /// Advance the clock. Returns the length of the window that just closed
    /// when one did — the caller records a summary carrying it as `window_ms`
    /// — and nil otherwise.
    ///
    /// The **first call opens the window and does not fire**: a summary at
    /// the moment a session is admitted would carry nothing but zeros. Each
    /// closing call opens the next window at its own reading, so a tick that
    /// arrives late (the loop was blocked) reports the window it actually
    /// measured rather than a nominal one.
    ///
    /// A clock that reads *earlier* than the window's start re-opens the
    /// window there and does not fire. The monotonic clock cannot step
    /// backwards, but the sampler cannot know its caller used one, and the
    /// wrapped subtraction would otherwise read the step as a window some
    /// five hundred years long and fire on it.
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

    /// Forget the open window, so the next call opens a fresh one. For a
    /// session that ends and begins again on the same object.
    public mutating func reset() {
        windowStartNs = nil
    }
}
