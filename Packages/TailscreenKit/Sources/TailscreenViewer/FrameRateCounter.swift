import Foundation

/// Frames per second over a sliding ~1 s window, for the viewer's stats HUD.
///
/// **Not** thread-safe: a `VideoSink`'s `present` is driven serially by the
/// session, the only place this is stepped.
///
/// Known limitation: the reading only updates when a frame arrives, so a
/// frozen sharer leaves the last fps standing instead of decaying to zero.
public struct FrameRateCounter {
    /// 1s: short enough to react, long enough not to flicker at 60 fps.
    public static let windowNs: UInt64 = 1_000_000_000

    /// Optional rather than a `0` sentinel, since 0 is a legitimate timestamp.
    private var windowStartNs: UInt64?
    private var framesInWindow = 0

    public init() {}

    /// Counts one frame; returns the window's fps once the window closes,
    /// else nil (cheap to call every frame — the host only publishes on a
    /// real update).
    ///
    /// Reading = frames in window ÷ elapsed; the frame that opens a window
    /// counts toward it, the frame that closes one does not carry over —
    /// accurate to within a frame, so an exact-integer test may be off by one.
    public mutating func record(nowNs: UInt64) -> Int? {
        guard let startNs = windowStartNs else {
            // First frame starts the window rather than closing one, or the
            // fps would divide by a near-zero elapsed time.
            windowStartNs = nowNs
            framesInWindow = 1
            return nil
        }
        framesInWindow += 1
        let elapsedNs = nowNs &- startNs
        guard elapsedNs >= Self.windowNs else { return nil }
        let fps = Int((Double(framesInWindow) * 1_000_000_000.0 / Double(elapsedNs)).rounded())
        // Next window starts now (not one window-length after the last
        // start), so slow frames don't make it drift from the recent past.
        windowStartNs = nowNs
        framesInWindow = 0
        return fps
    }

    /// Forget the current window — else a new session's first frame would
    /// close a window that started during the previous one.
    public mutating func reset() {
        windowStartNs = nil
        framesInWindow = 0
    }
}
