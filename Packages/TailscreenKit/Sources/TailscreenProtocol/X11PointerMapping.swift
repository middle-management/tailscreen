import Foundation

/// Arithmetic between a viewer's normalized `[0, 1]` pointer coordinate and
/// what X11's XTEST extension wants.
///
/// Smaller than ``WindowsPointerMapping`` because `XTestFakeMotionEvent`
/// takes plain root-window pixels — no `0…65535` virtual-desktop rescale.
/// The normalized → pixel step is shared via ``ScreenRegion``; only X11's
/// quirks live here.
///
/// **Scrolling is buttons, not deltas** — a scroll is press/release of
/// button 4/5/6/7 (up/down/left/right), once per notch. A continuous delta
/// must become a repeat count without truncating away sub-notch scrolls,
/// overflowing on a fling/hostile large delta, or flipping sign.
public enum X11PointerMapping {
    /// Scroll notches per line of `InputEvent` delta. 1, since X11's
    /// button-per-notch model already matches the wire's line units (unlike
    /// Windows' `WHEEL_DELTA` of 120).
    public static let notchesPerLine = 1.0

    /// Ceiling on notches per event — each notch is a real press/release
    /// pair on the X server, so an unbounded count from a hostile delta would
    /// flood it. 32 is well past any real single-event gesture.
    public static let maxNotchesPerEvent = 32

    /// X11 button numbers for scrolling, as the server defines them.
    public enum ScrollButton: Int, Sendable, Equatable, CaseIterable {
        case up = 4
        case down = 5
        case left = 6
        case right = 7
    }

    /// One scroll event as the button/press-count that performs it. Nil when
    /// the delta rounds to nothing.
    ///
    /// Positive `delta` scrolls content away from the user (wheel-up)
    /// vertically, right horizontally — matches
    /// `WindowsPointerMapping.wheelDelta`'s convention.
    public static func scroll(delta: Double, axis: Axis) -> (button: ScrollButton, count: Int)? {
        guard delta.isFinite, delta != 0 else { return nil }  // wire-supplied; non-finite → zero, not a trap
        let notches = Int((abs(delta) * notchesPerLine).rounded())
        // Round, don't truncate: truncation would drop every sub-line scroll.
        let count = min(max(notches, 1), maxNotchesPerEvent)
        switch axis {
        case .vertical: return (delta > 0 ? .up : .down, count)
        case .horizontal: return (delta > 0 ? .right : .left, count)
        }
    }

    public enum Axis: Sendable, Equatable {
        case vertical
        case horizontal
    }

    /// X11 button number for a wire mouse button: 1/2/3, with middle=2 and
    /// right=3 — reversed from every other platform's enum order, hence a
    /// named function rather than `rawValue + 1`.
    public static func buttonNumber(_ button: InputEvent.MouseButton) -> Int {
        switch button {
        case .left: return 1
        case .middle: return 2
        case .right: return 3
        }
    }
}
