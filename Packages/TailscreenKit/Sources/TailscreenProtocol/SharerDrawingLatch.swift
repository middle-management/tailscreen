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
    /// The surface exists, but could not take the keyboard. A refusal, not a
    /// warning: the drawing surface swallows the pointer over the whole
    /// shared region, and the only way out is a key — a surface that took
    /// the clicks but not the key traps the sharer under it.
    case noKeyboard
}

/// What a host's drawing surface answered when asked to arm.
public enum SharerDrawingArmResult: Sendable, Equatable {
    case armed
    case refused(SharerDrawingRefusal)
}

/// What a host should do with its drawing surface for a given request.
///
/// Separate from ``SharerDrawingLatch`` because it's about the *window's*
/// lifetime, not the tool's: X11's overlay exists for the whole share and
/// merely changes its input region, while Windows creates/destroys on
/// arm/disarm.
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
    ///   - hasRegion: whether this share knows where its content is on
    ///     screen. Windows resolves that from the capture item's size and
    ///     can fail; without it a stroke has no coordinates to normalize.
    ///
    /// `keep` matters because rebuilding a surface that's already up means
    /// dropping keyboard focus and re-asking for it, and asking can fail —
    /// switching pen to arrow would otherwise silently end drawing.
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
/// Load-bearing out of proportion to its size: arming hands the whole shared
/// region to a window that eats every click, with the hub's off button
/// underneath it. The sequencing below is a safety property, identical on
/// X11 (override-redirect window) and Win32 (topmost popup that can lose
/// focus to Alt-Tab) so the two can't disagree about a trapped desktop.
///
/// The rules, each pinned by ``SharerDrawingLatchTests``:
///
///   * **Tapping the armed tool again disarms**, matching the viewer toolbar.
///   * **A refusal disarms the surface anyway** — "no" can mean it got
///     half way (took the clicks, missed the keyboard).
///   * **Teardown disarms unconditionally**, even if this latch believes
///     nothing is armed, in case an arm ever half-succeeded.
///   * **Switching tools mid-draw does not disarm first**, so the surface —
///     and the sharer's keyboard focus — survives a change of pen.
///
/// The surface is an injected closure returning ``SharerDrawingArmResult``,
/// letting every case be tested with no window, no compositor, no message
/// pump — the same seam `SendInputInjector` uses.
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
        // Re-tapping the armed tool means "stop", matching the viewer toolbar.
        let wanted = (tool == activeTool) ? nil : tool
        guard let wanted else {
            disarm(surface: surface)
            return false
        }
        let result = surface(wanted)
        guard result == .armed else {
            // Disarm on refusal unconditionally: the host can't tell us how
            // far the failure got (took clicks but missed the keyboard?),
            // so one redundant call is the price of not needing to know.
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
    /// the surface reporting it lost the keyboard. Losing the keyboard must
    /// end drawing, not merely be noticed, since the window still swallows
    /// every click over the region.
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
