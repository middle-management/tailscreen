import Foundation

/// The arithmetic between a viewer's normalized `[0, 1]` pointer coordinate
/// and what X11's XTEST extension wants.
///
/// The Linux counterpart of ``WindowsPointerMapping``, and much smaller,
/// because X11 asks for less: `XTestFakeMotionEvent` takes plain root-window
/// pixels, so there is no second stage and none of Windows' `0…65535`
/// virtual-desktop rescale. The normalized → pixel step is therefore shared
/// outright — see ``ScreenRegion`` — and what is left here is the one thing
/// X11 does differently from every other platform.
///
/// **Scrolling on X11 is buttons, not deltas.** There is no wheel value in the
/// core protocol: a scroll is a press-and-release of button 4 (up), 5 (down),
/// 6 (left) or 7 (right), once per notch. So a continuous delta has to become
/// a repeat count, which is integer arithmetic with the usual ways to be
/// wrong — a truncating conversion swallows every sub-notch scroll, an
/// unclamped one turns a fling (or a hostile peer's `1e9`) into a million
/// synthetic clicks, and a sign error scrolls the wrong way. All three are
/// tested here, where no X server is needed.
public enum X11PointerMapping {
    /// How many scroll notches one line of `InputEvent` delta is worth.
    ///
    /// One. X11's button-per-notch model already matches the wire's line
    /// units, so unlike Windows' `WHEEL_DELTA` of 120 there is no scale — the
    /// constant exists to be named rather than to convert.
    public static let notchesPerLine = 1.0

    /// The most notches one event may produce.
    ///
    /// A ceiling, not a scale: each notch is a real button press-and-release
    /// pair on the X server, so an unbounded count is a denial-of-service
    /// vector from a peer that sends a large delta, and even an honest
    /// trackpad fling would freeze the desktop for a moment. 32 notches is
    /// well past what any real gesture produces in one event.
    public static let maxNotchesPerEvent = 32

    /// X11 button numbers for scrolling, as the server defines them.
    public enum ScrollButton: Int, Sendable, Equatable, CaseIterable {
        case up = 4
        case down = 5
        case left = 6
        case right = 7
    }

    /// One scroll event as the button presses that perform it.
    ///
    /// Returns the button and how many press/release pairs to send. Nil when
    /// the delta rounds to nothing, so a caller can skip the round trip
    /// entirely rather than injecting a zero-count no-op.
    ///
    /// Sign follows the rest of the protocol: positive `delta` scrolls the
    /// content **away from the user** (wheel-up) vertically and **right**
    /// horizontally, matching `WindowsPointerMapping.wheelDelta`'s convention
    /// so a viewer's gesture feels the same whichever sharer it reaches.
    public static func scroll(delta: Double, axis: Axis) -> (button: ScrollButton, count: Int)? {
        // Wire-supplied, so non-finite is zero rather than a trap — the same
        // defensive rule every mapping in this family follows.
        guard delta.isFinite, delta != 0 else { return nil }
        let notches = Int((abs(delta) * notchesPerLine).rounded())
        // `.rounded()` before the Int conversion, not truncation: a 0.6-line
        // scroll is a real scroll and must move something, and truncating
        // would silently discard every gesture smaller than a full line — the
        // "my trackpad does nothing on Linux" bug.
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

    /// X11 button number for a wire mouse button.
    ///
    /// 1/2/3 rather than 0/1/2, and middle is **2** while right is **3** —
    /// the opposite pairing to every other platform's enum order, which is
    /// exactly why this is a named function with a test rather than an inline
    /// `rawValue + 1`.
    public static func buttonNumber(_ button: InputEvent.MouseButton) -> Int {
        switch button {
        case .left: return 1
        case .middle: return 2
        case .right: return 3
        }
    }
}
