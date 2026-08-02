import Foundation

/// A rectangle in screen pixels, and the one piece of pointer arithmetic every
/// platform needs: where a viewer's normalized `[0, 1]` point inside the
/// captured region lands on the sharer's screen.
///
/// Origin top-left, y down — the convention Win32's `RECT` and X11's root
/// window both use. `x`/`y` may be negative on a multi-monitor desktop.
///
/// Extracted when the Linux injector needed exactly what
/// ``WindowsPointerMapping/screenPoint(normalizedX:normalizedY:in:)`` already
/// did. The alternative was six duplicated lines, which is how two clamps that
/// must agree start disagreeing — and this particular clamp is a security
/// boundary, not a convenience: it is what stops a hostile viewer placing the
/// sharer's pointer outside the region its user can actually see.
///
/// Windows keeps its own name for it (`WindowsPointerMapping.ScreenRect` is a
/// typealias) because it has a *second* stage on top — the `0…65535`
/// virtual-desktop rescale `SendInput` wants — which is genuinely
/// Windows-only. X11 and macOS stop here.
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
    /// rejected**: these arrive over the wire from a peer, and dropping them
    /// would let a rounding error at the region's edge feel like a dead zone
    /// while accepting them would let a buggy — or hostile — viewer move the
    /// pointer anywhere on the sharer's desktop. NaN maps to the origin, the
    /// same defensive choice `RemoteControlMapping.globalPoint` makes on macOS.
    public func point(normalizedX: Double, normalizedY: Double) -> (x: Int, y: Int) {
        // `width - 1`, not `width`: a region `width` pixels wide has its last
        // addressable column at `width - 1`, and nx == 1.0 must reach it.
        // Off by one here makes the screen edge — where scrollbars, the close
        // button and the dock live — permanently unclickable.
        let px = x + Int((Self.clampUnit(normalizedX) * Double(max(0, width - 1))).rounded())
        let py = y + Int((Self.clampUnit(normalizedY) * Double(max(0, height - 1))).rounded())
        return (px, py)
    }

    static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
