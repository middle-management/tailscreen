import Foundation

/// Frames per second over a sliding ~1 s window, for the viewer's stats HUD.
///
/// Portable for the same reason `I420Converter` and `MonoPCMConverter` are:
/// it is arithmetic every renderer backend needs, no backend can test it in
/// place, and the alternative is one copy per host drifting apart. It lived
/// inline in the GTK sink; the Windows viewer needed the identical thing.
///
/// **Not** thread-safe, and deliberately so: a `VideoSink`'s `present` is
/// driven serially by the session, which is the only place this is stepped.
/// Making it a lock would suggest a concurrency guarantee the callers do not
/// need and would pay for once per frame.
///
/// Known limitation, inherited rather than introduced: the reading is only
/// updated when a frame arrives, so a stream that STOPS leaves the last value
/// standing rather than decaying to zero. A viewer whose sharer froze reads
/// "30 fps" until the next frame or a disconnect. Fixing that needs a clock
/// the counter does not have — the host would have to tick it — and is worth
/// doing when something other than a cosmetic HUD depends on the number.
public struct FrameRateCounter {
    /// Window length. One second is short enough to react to a real change and
    /// long enough that the number does not flicker at 60 fps.
    public static let windowNs: UInt64 = 1_000_000_000

    /// Optional rather than a `0` sentinel: zero is a legitimate timestamp,
    /// and a counter that treats it as "not started" never reports at all.
    /// The inline version this replaces used the sentinel and got away with it
    /// only because `DispatchTime.now().uptimeNanoseconds` is never 0 on a
    /// running machine — which is a property of the caller, not of the
    /// arithmetic.
    private var windowStartNs: UInt64?
    private var framesInWindow = 0

    public init() {}

    /// Count one frame, and return the window's fps if the window just closed.
    ///
    /// The reading is `frames observed in the window ÷ elapsed`, where the
    /// frame that OPENS a window counts toward it and the frame that CLOSES
    /// one does not carry into the next. At a steady rate that is accurate to
    /// within a frame, which is all a HUD needs and is worth saying out loud
    /// so a test asserting an exact integer knows why it may be off by one.
    ///
    /// Returns nil on every other frame, which is what makes this cheap to
    /// call per frame: the host publishes only when there is something new to
    /// publish, rather than recomputing state 60 times a second.
    public mutating func record(nowNs: UInt64) -> Int? {
        // First frame ever (or since a reset) starts the window rather than
        // closing one — otherwise the first reading would be computed against
        // an epoch of zero and come out as a nonsense several-billion fps.
        guard let startNs = windowStartNs else {
            windowStartNs = nowNs
            framesInWindow = 1
            return nil
        }
        framesInWindow += 1
        let elapsedNs = nowNs &- startNs
        guard elapsedNs >= Self.windowNs else { return nil }
        let fps = Int((Double(framesInWindow) * 1_000_000_000.0 / Double(elapsedNs)).rounded())
        // The next window starts NOW rather than one window-length after the
        // last start. Over a run of slow frames the two drift apart, and
        // anchoring to the last observation is what keeps the reading about
        // the recent past rather than about an accumulating schedule.
        windowStartNs = nowNs
        framesInWindow = 0
        return fps
    }

    /// Forget the current window.
    ///
    /// Sinks outlive one viewing session on both hosts, so without this the
    /// first frame of a new session closes a window that started during the
    /// previous one — reporting a fraction of an fps across the gap.
    public mutating func reset() {
        windowStartNs = nil
        framesInWindow = 0
    }
}
