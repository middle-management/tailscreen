import Foundation

/// The arithmetic between a viewer's normalized `[0, 1]` pointer coordinate
/// and what Windows' `SendInput` wants.
///
/// Extracted from the injector for the same reason `MacKeyCodeMapping` and
/// `BGRAToI420` were: it is pure integer arithmetic with several ways to be
/// subtly wrong, and none of them can be checked on the machine that runs it.
/// Every case below is a real trap:
///
///   * `SendInput`'s absolute coordinates are `0…65535` across the **virtual
///     desktop**, not the screen and not the captured region — so the
///     conversion is two steps, and skipping the first is the classic
///     "the pointer only works on the primary monitor" bug.
///   * The virtual desktop's origin is **negative** when a monitor sits left
///     of or above the primary one, so the offset cannot be assumed to be
///     zero.
///   * The scale factor is `65535 / (extent - 1)`, not `65535 / extent`. With
///     the wrong one the last pixel column is unreachable — invisible in
///     testing and infuriating in use, because it is exactly where scrollbars,
///     the Close button and the screen edge live.
///
/// Coordinates in, coordinates out. No Win32 in this file, so Linux CI runs
/// the tests.
public enum WindowsPointerMapping {
    /// A rectangle in **screen pixels**, matching Win32's `RECT`-derived
    /// convention: origin top-left, y down. `x`/`y` may be negative on a
    /// multi-monitor desktop.
    public struct ScreenRect: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Where a normalized `[0, 1]` point inside the captured region lands in
    /// screen pixels.
    ///
    /// Out-of-range and non-finite inputs are clamped rather than rejected:
    /// these arrive over the wire from a peer, and a hostile or buggy viewer
    /// must not be able to place the pointer outside the region its user can
    /// see. NaN maps to the region's origin — the same defensive choice
    /// `RemoteControlMapping.globalPoint` makes on macOS.
    public static func screenPoint(
        normalizedX: Double,
        normalizedY: Double,
        in region: ScreenRect
    ) -> (x: Int, y: Int) {
        let clampedX = clampUnit(normalizedX)
        let clampedY = clampUnit(normalizedY)
        // `width - 1` for the same reason as the scale factor below: a region
        // `width` pixels wide has its last addressable column at `width - 1`,
        // and nx == 1.0 must reach it.
        let x = region.x + Int((clampedX * Double(max(0, region.width - 1))).rounded())
        let y = region.y + Int((clampedY * Double(max(0, region.height - 1))).rounded())
        return (x, y)
    }

    /// Screen pixels → the `0…65535` absolute coordinates `SendInput` takes
    /// with `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`.
    ///
    /// - Parameter virtualDesktop: the whole virtual desktop's bounds
    ///   (`SM_XVIRTUALSCREEN` / `SM_YVIRTUALSCREEN` / `SM_CXVIRTUALSCREEN` /
    ///   `SM_CYVIRTUALSCREEN`). Its origin is negative when a monitor is left
    ///   of or above the primary.
    ///
    /// The result is clamped to `0…65535`: a point outside the virtual desktop
    /// would otherwise wrap through the `Int32` conversion into a wildly
    /// different screen position.
    public static func absolutePoint(
        screenX: Int,
        screenY: Int,
        virtualDesktop: ScreenRect
    ) -> (x: Int32, y: Int32) {
        (
            axis(screenX, origin: virtualDesktop.x, extent: virtualDesktop.width),
            axis(screenY, origin: virtualDesktop.y, extent: virtualDesktop.height)
        )
    }

    /// Convenience: normalized-in-region straight to `SendInput` coordinates.
    public static func absolutePoint(
        normalizedX: Double,
        normalizedY: Double,
        in region: ScreenRect,
        virtualDesktop: ScreenRect
    ) -> (x: Int32, y: Int32) {
        let screen = screenPoint(normalizedX: normalizedX, normalizedY: normalizedY, in: region)
        return absolutePoint(screenX: screen.x, screenY: screen.y, virtualDesktop: virtualDesktop)
    }

    /// One `InputEvent` scroll delta (line units) as Windows wheel units.
    ///
    /// `WHEEL_DELTA` is 120 per detent, and Windows treats it as a signed
    /// 16-bit value packed into `mouseData` — hence the saturation rather
    /// than a wrapping conversion. Wire-supplied, so NaN and infinity are
    /// zero rather than a trap.
    ///
    /// Sign matches the other end: positive `deltaY` is a wheel rotation away
    /// from the user, and positive `deltaX` a tilt to the right.
    public static func wheelDelta(_ lines: Double) -> Int32 {
        guard lines.isFinite else { return 0 }
        let scaled = (lines * Double(wheelDeltaPerLine)).rounded()
        if scaled >= Double(Int16.max) { return Int32(Int16.max) }
        if scaled <= Double(Int16.min) { return Int32(Int16.min) }
        return Int32(scaled)
    }

    /// `WHEEL_DELTA` from the Win32 headers.
    public static let wheelDeltaPerLine = 120

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func axis(_ value: Int, origin: Int, extent: Int) -> Int32 {
        // A one-pixel-wide desktop is degenerate but reachable (and a
        // zero-width one would divide by zero), so it collapses to 0 rather
        // than trapping.
        guard extent > 1 else { return 0 }
        let offset = value - origin
        let scaled = (Double(offset) * 65535.0 / Double(extent - 1)).rounded()
        if scaled <= 0 { return 0 }
        if scaled >= 65535 { return 65535 }
        return Int32(scaled)
    }
}
