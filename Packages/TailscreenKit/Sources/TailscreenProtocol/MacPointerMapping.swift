import Foundation

/// The arithmetic between a viewer's ``InputEvent/scroll(x:y:deltaX:deltaY:modifiers:)``
/// line deltas and the integer wheel counts `CGEvent`'s
/// `scrollWheelEvent2Source` wants — the macOS counterpart of
/// ``X11PointerMapping``'s notch count and ``WindowsPointerMapping/wheelDelta(_:)``.
///
/// Unlike X11 (`max(…, 1)` floor) or Windows (`WHEEL_DELTA` scaling before
/// rounding), `CGEventCreateScrollWheelEvent2` in `.line` units rounds a
/// delta below half a line to zero — and sub-line deltas are the common case
/// (a trackpad's ~0.1–0.5-line stream, `RemoteControlInputView.scrollWheel`),
/// so naive rounding made scrolling do nothing.
///
/// ``ScrollLineAccumulator`` keeps the remainder across events instead of
/// discarding it, so a slow gesture scrolls slowly rather than not at all.
public enum MacPointerMapping {
    /// The most whole lines one injected event may carry. A ceiling, not a
    /// scale (same role/value as ``X11PointerMapping/maxNotchesPerEvent``):
    /// unclamped, a hostile viewer could scroll a document to its end via
    /// `Int32.max`.
    public static let maxLinesPerEvent: Int32 = 32

    /// Carries the sub-line remainder of a scroll gesture across events.
    ///
    /// Not thread-safe by design — the injector confines one instance to its
    /// serial queue, the same way it confines its pressed-button state.
    public struct ScrollLineAccumulator: Sendable, Equatable {
        /// Undelivered fraction of a line, per axis. Always in `(-1, 1)`.
        private var residualX: Double = 0
        private var residualY: Double = 0

        public init() {}

        /// True when both axes have nothing pending. Exposed so `reset()`'s
        /// effect is assertable.
        public var isEmpty: Bool { residualX == 0 && residualY == 0 }

        /// Drop any pending fraction. Called on grant end, so a leftover
        /// half-line doesn't ride into the next controller's first scroll.
        public mutating func reset() {
            residualX = 0
            residualY = 0
        }

        /// Fold one wire event's deltas in and take out whatever whole lines
        /// have accumulated, keeping the remainder. Returns nil when nothing
        /// whole came out, so the caller skips a zero-scroll `CGEvent`.
        public mutating func take(deltaX: Double, deltaY: Double) -> (wheelX: Int32, wheelY: Int32)? {
            let x = Self.step(&residualX, delta: deltaX)
            let y = Self.step(&residualY, delta: deltaY)
            guard x != 0 || y != 0 else { return nil }
            return (wheelX: x, wheelY: y)
        }

        /// One axis: accumulate, split off the whole part, keep the fraction.
        private static func step(_ residual: inout Double, delta: Double) -> Int32 {
            // Wire-supplied: a non-finite delta must not poison the residual
            // into a permanent NaN.
            guard delta.isFinite else { return 0 }
            let total = residual + delta
            guard total.isFinite else {
                residual = 0
                return 0
            }
            // Toward zero, not `.rounded()`: the remainder must keep the
            // movement's sign, or 0.6 lines would emit 1 and owe -0.4 back.
            let whole = total.rounded(.towardZero)
            if whole >= Double(MacPointerMapping.maxLinesPerEvent) {
                // Drop the excess rather than bank it, so an absurd delta
                // clamps once instead of clamping every event after.
                residual = 0
                return MacPointerMapping.maxLinesPerEvent
            }
            if whole <= Double(-MacPointerMapping.maxLinesPerEvent) {
                residual = 0
                return -MacPointerMapping.maxLinesPerEvent
            }
            residual = total - whole
            return Int32(whole)
        }
    }
}
