import Foundation

/// The arithmetic between a viewer's ``InputEvent/scroll(x:y:deltaX:deltaY:modifiers:)``
/// line deltas and the integer wheel counts `CGEvent`'s
/// `scrollWheelEvent2Source` wants — the macOS counterpart of
/// ``X11PointerMapping``'s notch count and ``WindowsPointerMapping/wheelDelta(_:)``.
///
/// **The one thing macOS does differently is that its scroll unit is an
/// `Int32`.** X11 turns a delta into a repeat count with a `max(…, 1)` floor,
/// and Windows multiplies by `WHEEL_DELTA` (120) before rounding, so on both
/// of those a fraction of a line still moves something. `CGEventCreateScrollWheelEvent2`
/// in `.line` units has no such headroom: a delta below half a line rounds to
/// zero and the event scrolls nothing at all.
///
/// That matters because sub-line deltas are the *common* case, not the exotic
/// one. A trackpad viewer reports scroll in points and scales them to lines
/// (`RemoteControlInputView.scrollWheel`), so an ordinary two-finger drag is a
/// stream of ~0.1–0.5-line events — every one of which rounded away, which is
/// what "scrolling does nothing on the sharer" looked like.
///
/// ``ScrollLineAccumulator`` fixes it by keeping the remainder instead of
/// discarding it: the fractions add up across events until they make a whole
/// line, so a slow gesture scrolls slowly rather than not at all, and the
/// total distance scrolled matches the total delta sent.
public enum MacPointerMapping {
    /// The most whole lines one injected event may carry.
    ///
    /// A ceiling, not a scale — the same role (and value) as
    /// ``X11PointerMapping/maxNotchesPerEvent``. `CGEvent` will happily accept
    /// `Int32.max` and scroll a document to its end, so an unclamped path is a
    /// vandalism vector from a granted-but-hostile viewer, and a real gesture
    /// never comes near 32 lines in a single event.
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

        /// True when both axes have nothing pending — the state a fresh
        /// accumulator and a fully-delivered gesture share. Exposed so
        /// `reset()`'s effect is assertable.
        public var isEmpty: Bool { residualX == 0 && residualY == 0 }

        /// Drop any pending fraction.
        ///
        /// Called when a grant ends: a half-line left over from the previous
        /// controller must not ride along into the next one's first scroll.
        public mutating func reset() {
            residualX = 0
            residualY = 0
        }

        /// Fold one wire event's deltas in and take out whatever whole lines
        /// have accumulated, keeping the remainder for next time.
        ///
        /// Returns `nil` when nothing whole came out, so the caller can skip
        /// constructing a `CGEvent` that would scroll zero — a real no-op, and
        /// the expected result for most events of a slow gesture.
        public mutating func take(deltaX: Double, deltaY: Double) -> (wheelX: Int32, wheelY: Int32)? {
            let x = Self.step(&residualX, delta: deltaX)
            let y = Self.step(&residualY, delta: deltaY)
            guard x != 0 || y != 0 else { return nil }
            return (wheelX: x, wheelY: y)
        }

        /// One axis: accumulate, split off the whole part, keep the fraction.
        private static func step(_ residual: inout Double, delta: Double) -> Int32 {
            // Wire-supplied, so a non-finite delta contributes nothing rather
            // than poisoning the residual into a permanent NaN — the same
            // defensive rule every mapping in this family follows.
            guard delta.isFinite else { return 0 }
            let total = residual + delta
            guard total.isFinite else {
                residual = 0
                return 0
            }
            // Toward zero, not `.rounded()`: the fraction that is left must
            // keep the sign of the movement, or a 0.6-line event would emit a
            // whole line and then owe 0.4 back in the other direction.
            let whole = total.rounded(.towardZero)
            if whole >= Double(MacPointerMapping.maxLinesPerEvent) {
                // Saturating drops the excess instead of banking it, so an
                // absurd delta is one clamped scroll rather than a clamped
                // scroll every event from here on.
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
