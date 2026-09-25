import Foundation

/// A rectangle in screen pixels, and the one piece of pointer arithmetic
/// every platform needs: where a viewer's normalized `[0, 1]` point inside
/// the captured region lands on the sharer's screen.
///
/// Origin top-left, y down — the convention Win32's `RECT` and X11's root
/// window both use. `x`/`y` may be negative on a multi-monitor desktop.
///
/// Shared by the Linux and Windows injectors so this clamp — a security
/// boundary, not a convenience, stopping a hostile viewer placing the
/// pointer outside the region its user can see — can't disagree between
/// them. Windows keeps its own name (`WindowsPointerMapping.ScreenRect` is a
/// typealias) since it has a further `0…65535` virtual-desktop rescale
/// `SendInput` wants; X11 and macOS stop here.
public struct ScreenRegion: Sendable, Equatable {
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

    /// Where a normalized `[0, 1]` point inside this region lands, in screen
    /// pixels.
    ///
    /// Out-of-range and non-finite inputs are **clamped rather than
    /// rejected**: these arrive over the wire from a peer, so accepting them
    /// unclamped would let a hostile viewer move the pointer anywhere. NaN
    /// maps to the origin, matching `RemoteControlMapping.globalPoint`.
    public func point(normalizedX: Double, normalizedY: Double) -> (x: Int, y: Int) {
        // `width - 1`, not `width`: nx == 1.0 must reach the last addressable
        // column, or the screen edge (scrollbars, close button, dock)
        // becomes permanently unclickable.
        let px = x + Int((Self.clampUnit(normalizedX) * Double(max(0, width - 1))).rounded())
        let py = y + Int((Self.clampUnit(normalizedY) * Double(max(0, height - 1))).rounded())
        return (px, py)
    }

    /// Where a pixel inside this region sits in normalized `[0, 1]` — the
    /// exact inverse of ``point(normalizedX:normalizedY:)``. Needed by a
    /// **sharer** drawing on its own screen, converting pixels back into the
    /// space every peer speaks.
    ///
    /// Three things it must get right, silent when wrong:
    ///
    ///   * Divisor is `width - 1`, matching `point`'s multiplier — otherwise
    ///     a sharer's stroke and a viewer's click on the same pixel no
    ///     longer name the same place.
    ///   * Coordinates arrive **negative** (a drag past the surface, Win32
    ///     mouse capture / X11 implicit grab). Win32 packs a *signed* 16-bit
    ///     pair, so reading `-3` via `LOWORD` instead of sign-extending
    ///     yields `65533` and teleports the stroke to the far edge. Clamping
    ///     pins it near instead.
    ///   * A degenerate one-pixel region divides by zero, collapsing to the
    ///     origin rather than trapping.
    public func normalizedPoint(screenX: Int, screenY: Int) -> (x: Double, y: Double) {
        (
            Self.normalizedAxis(screenX - x, extent: width),
            Self.normalizedAxis(screenY - y, extent: height)
        )
    }

    static func normalizedAxis(_ offset: Int, extent: Int) -> Double {
        guard extent > 1 else { return 0 }
        return min(max(Double(offset) / Double(extent - 1), 0), 1)
    }

    static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
