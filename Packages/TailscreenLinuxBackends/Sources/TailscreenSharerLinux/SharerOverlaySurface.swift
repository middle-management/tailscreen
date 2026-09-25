import Foundation
import TailscreenProtocol

/// What the share engine needs from the sharer-side annotation overlay.
///
/// A seam rather than a concrete type: the overlay (`CGtkOverlay`) is a GTK
/// window living in the app target, and this package links no UI toolkit so
/// Linux CI can build/test the engine headless. The app conforms its
/// `SharerAnnotationOverlay`; a session with no overlay hands back nil and
/// the engine withholds `ScreenShareCaps.annotations`.
///
/// `Sendable`: the engine captures the surface in the server's annotation
/// callback (control-channel thread); the concrete overlay marshals GTK
/// calls onto the main thread itself. `setInteractive` alone is
/// main-thread-only by contract, and only the `@MainActor` engine calls it.
public protocol SharerOverlaySurface: AnyObject, Sendable {
    /// The sharer's pointer while drawing is armed. Phases are 0 = pressed,
    /// 1 = dragged, 2 = released; the point is normalized over the capture
    /// region. Fires on the GTK main thread.
    var onPointer: ((Int, CGPoint) -> Void)? { get set }
    /// The sharer pressed Escape and wants out of drawing mode. Fires on the
    /// GTK main thread.
    var onEscape: (() -> Void)? { get set }

    /// Arm or disarm sharer drawing. False on arm means the surface couldn't
    /// also take the keyboard — treat as a refusal. GTK main thread only.
    func setInteractive(_ on: Bool) -> Bool
    /// Apply one annotation op — from a viewer, or from the sharer's own
    /// drawing. Callable from any thread.
    func apply(_ op: AnnotationOp)
    /// Clear every stroke and hide. Callable from any thread.
    func clear()
    /// Turn the capture outline on or off. Callable from any thread.
    func setShowsOutline(_ on: Bool)
}
