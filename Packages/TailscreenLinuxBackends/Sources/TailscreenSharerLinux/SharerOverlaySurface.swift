import Foundation
import TailscreenProtocol

/// What the share engine needs from the sharer-side annotation overlay.
///
/// A seam rather than a concrete type because the overlay is a GTK window —
/// `CGtkOverlay` lives in the app target, and this package deliberately links
/// no UI toolkit so Linux CI can build and test the engine headless. The app
/// conforms its `SharerAnnotationOverlay` and hands the engine a factory; a
/// session that cannot host an overlay hands back nil and the engine withholds
/// `ScreenShareCaps.annotations`, exactly as before the split.
///
/// `Sendable` because the engine captures the surface in the server's
/// annotation callback, which fires on the control-channel thread. The
/// concrete overlay already marshals every GTK call onto the main thread
/// itself — that thread-safety is the property this requirement names. The
/// one call that is main-thread-only by contract, `setInteractive`, is only
/// ever made by the engine, which is `@MainActor`.
public protocol SharerOverlaySurface: AnyObject, Sendable {
    /// The sharer's pointer while drawing is armed. Phases are 0 = pressed,
    /// 1 = dragged, 2 = released; the point is normalized over the capture
    /// region. Fires on the GTK main thread.
    var onPointer: ((Int, CGPoint) -> Void)? { get set }
    /// The sharer pressed Escape and wants out of drawing mode. Fires on the
    /// GTK main thread.
    var onEscape: (() -> Void)? { get set }

    /// Arm or disarm sharer drawing. A false on arm means the surface could
    /// not also take the keyboard, and the caller must treat it as a refusal —
    /// see `SharerAnnotationOverlay.setInteractive`. GTK main thread only.
    func setInteractive(_ on: Bool) -> Bool
    /// Apply one annotation op — from a viewer, or from the sharer's own
    /// drawing. Callable from any thread.
    func apply(_ op: AnnotationOp)
    /// Clear every stroke and hide. Callable from any thread.
    func clear()
    /// Turn the capture outline on or off. Callable from any thread.
    func setShowsOutline(_ on: Bool)
}
