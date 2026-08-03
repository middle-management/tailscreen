import Foundation

/// Why a sharer's drawing surface would not arm.
///
/// Two cases rather than one boolean, because the sharer needs different
/// sentences: one says this share never had a surface, the other says the
/// desktop refused it a keyboard just now and trying again might work.
public enum SharerDrawingRefusal: String, Sendable, Equatable, CaseIterable {
    /// This share has no drawing surface at all — no resolvable capture
    /// geometry (Windows), no compositor (Linux), or the window could not be
    /// built.
    case noSurface
    /// The surface exists, but could not take the keyboard.
    ///
    /// **This is a refusal, not a warning.** A drawing surface has to swallow
    /// the pointer over the whole shared region — that is the feature — and the
    /// only way back out from under it is a key. A surface that took the clicks
    /// and not the key is a window the sharer cannot dismiss, sitting over the
    /// button that would have dismissed it.
    case noKeyboard
}

/// What a host's drawing surface answered when asked to arm.
public enum SharerDrawingArmResult: Sendable, Equatable {
    case armed
    case refused(SharerDrawingRefusal)
}

/// What a host should do with its drawing surface for a given request.
///
/// Separate from ``SharerDrawingLatch`` because it is about the *window's*
/// lifetime rather than the tool's, and the two answer different questions on
/// different hosts: the X11 sharer's overlay exists for the whole share and
/// merely changes its input region, while the Windows one is created on arm and
/// destroyed on disarm.
public enum SharerDrawingSurfacePlan: Sendable, Equatable {
    /// Nothing armed — drop the surface if there is one.
    case release
    /// Already up. **Leave it alone**, even though the tool changed.
    case keep
    /// Build one.
    case create
    /// Cannot: say why.
    case refuse(SharerDrawingRefusal)

    /// - Parameters:
    ///   - hasSurface: whether a surface is up right now.
    ///   - hasRegion: whether this share knows where its content is on screen.
    ///     Windows resolves that from the capture item's size and can fail;
    ///     without it a stroke has no coordinates to be normalized against.
    ///
    /// The `keep` case is the one worth having a name: rebuilding a surface
    /// that is already up means dropping keyboard focus and asking for it
    /// again, and asking is the step that is allowed to fail. A sharer who
    /// switched from the pen to the arrow would find drawing had silently
    /// ended, with a note about the keyboard they never touched.
    public static func plan(
        tool: AnnotationTool?, hasSurface: Bool, hasRegion: Bool
    ) -> SharerDrawingSurfacePlan {
        guard tool != nil else { return .release }
        if hasSurface { return .keep }
        guard hasRegion else { return .refuse(.noSurface) }
        return .create
    }
}

/// Which drawing tool a **sharer** has armed, and what to say when arming was
/// refused.
///
/// Small, and load-bearing out of proportion to its size. Arming hands the
/// whole shared region to a window that eats every click on the sharer's own
/// desktop; the hub window with the button that would turn it off is
/// underneath it. So the sequencing below is a safety property, not
/// bookkeeping, and it is identical on X11 (an override-redirect window the
/// window manager will never focus) and on Win32 (a topmost popup that can lose
/// focus to Alt-Tab). Both hosts run this rather than each writing the ordering
/// out again — the second copy is where the two would disagree, and the
/// disagreement is a desktop nobody can click.
///
/// The rules, each pinned by ``SharerDrawingLatchTests``:
///
///   * **Tapping the armed tool again disarms**, matching the viewer toolbar.
///   * **A refusal disarms the surface anyway.** The host said no, but "no" can
///     mean it got half way — took the clicks, missed the keyboard — and one
///     extra no-op call is cheap next to a trapped desktop.
///   * **Teardown disarms unconditionally**, even when this latch believes
///     nothing is armed. If an arm ever half-succeeded, the conditional version
///     is what leaves the surface up after the share ends.
///   * **Switching tools mid-draw does not disarm first**, so the surface — and
///     with it the sharer's keyboard focus — survives a change of pen.
///
/// The surface is an injected closure returning ``SharerDrawingArmResult``,
/// which is what lets every case above be tested on Linux with no window,
/// no compositor and no message pump — the same seam `SendInputInjector` uses
/// to test `SendInput` decisions where there is no `SendInput`.
public struct SharerDrawingLatch: Sendable, Equatable {
    /// Ask the host's surface to arm with `tool`, or to disarm when nil.
    /// A disarm's answer is ignored: there is no such thing as failing to stop.
    public typealias Surface = (AnnotationTool?) -> SharerDrawingArmResult

    /// The armed tool, or nil when the sharer is not drawing.
    public private(set) var activeTool: AnnotationTool?
    /// Why the last attempt to arm was refused. Cleared by a successful arm and
    /// by any disarm.
    public private(set) var refusal: SharerDrawingRefusal?

    public init() {}

    /// A toolbar tap. Returns whether drawing is armed afterwards.
    @discardableResult
    public mutating func select(_ tool: AnnotationTool?, surface: Surface) -> Bool {
        // Re-tapping the armed tool means "stop", the way it does on the
        // viewer's toolbar. Without it a one-tool toolbar has no off switch
        // except the key the sharer is being asked to trust.
        let wanted = (tool == activeTool) ? nil : tool
        guard let wanted else {
            disarm(surface: surface)
            return false
        }
        let result = surface(wanted)
        guard result == .armed else {
            // Disarm on refusal, unconditionally. The host reported failure,
            // but a host that got as far as showing a click-swallowing window
            // and then failed to take the keyboard has left exactly the trap
            // this type exists to prevent — and it cannot tell us how far it
            // got. One redundant call is the price of not needing to know.
            _ = surface(nil)
            activeTool = nil
            if case .refused(let why) = result { refusal = why }
            return false
        }
        activeTool = wanted
        refusal = nil
        return true
    }

    /// The sharer asked to stop drawing from the surface itself — Escape, or
    /// the surface reporting it lost the keyboard.
    ///
    /// Losing the keyboard has to end drawing, not merely be noticed: the
    /// window is still swallowing every click over the shared region, and
    /// Escape now goes to whatever took the focus.
    public mutating func release(surface: Surface) {
        disarm(surface: surface)
    }

    /// The share is ending. Always disarms, whatever this latch believes.
    public mutating func teardown(surface: Surface) {
        disarm(surface: surface)
    }

    private mutating func disarm(surface: Surface) {
        _ = surface(nil)
        activeTool = nil
        refusal = nil
    }
}
