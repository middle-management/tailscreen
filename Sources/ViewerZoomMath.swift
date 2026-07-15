import CoreGraphics

/// Continuous content-zoom state for the viewer window. `scale == 1` means
/// the video sits exactly at its aspect-fit rect; larger scales magnify the
/// video about the fit rect's center, shifted by `offset`. Pure value type —
/// all geometry lives in ``ViewerZoomMath`` so the decision math is
/// CI-testable without AppKit.
struct ViewerZoomState: Equatable {
    /// Content magnification relative to the aspect-fit rect. Every
    /// transition function clamps it to
    /// `ViewerZoomMath.minScale...ViewerZoomMath.maxScale`; 1.0 == fit.
    var scale: CGFloat = 1.0
    /// Pan offset of the zoomed video's center from the fit rect's center,
    /// in viewport points. Always `.zero` at scale 1.
    var offset: CGPoint = .zero
}

/// Pure zoom/pan geometry for the viewer's content zoom. The host view
/// (`AspectFitHostView`) feeds gesture deltas in and lays out both the
/// metal layer and the annotation overlay from the single rect
/// ``videoRect(fit:state:)`` returns — their congruence is what keeps
/// annotation coordinates video-relative at any zoom. Extracted per
/// CLAUDE.md's extract-the-decision pattern; covered by
/// `ViewerZoomMathTests` on CI.
enum ViewerZoomMath {
    /// Fully zoomed out == aspect-fit. Zooming below fit is not supported;
    /// the window-sizing presets (⌘0 / ⌘- / ⌘+) cover "smaller than fit".
    static let minScale: CGFloat = 1.0
    /// Preview-style ceiling — deep enough to read small text on a 5K
    /// share squeezed into a laptop-sized viewer window.
    static let maxScale: CGFloat = 8.0
    /// Target scale for the double-tap (smart-magnify) toggle.
    static let smartMagnifyScale: CGFloat = 2.0

    /// The rect the video (and the congruent annotation overlay) should
    /// occupy: `fit` scaled by `state.scale` about its own center, then
    /// shifted by `state.offset`. The offset is re-clamped here so a stale
    /// state (e.g. after a window resize shrank `fit`) can never open a
    /// gap between the video's edge and the fit rect's edge.
    static func videoRect(fit: CGRect, state: ViewerZoomState) -> CGRect {
        guard fit.width > 0, fit.height > 0 else { return fit }
        let scale = clampedScale(state.scale)
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        let offset = clampedOffset(state.offset, scale: scale, fit: fit)
        return CGRect(
            x: fit.midX + offset.x - size.width / 2,
            y: fit.midY + offset.y - size.height / 2,
            width: size.width,
            height: size.height)
    }

    /// State after zooming by the multiplicative `delta`, anchored at
    /// `anchor` (a viewport point): the video point under `anchor` before
    /// the zoom is still under `anchor` after it, up to the scale and
    /// offset clamps.
    static func zoomed(
        state: ViewerZoomState, by delta: CGFloat, anchor: CGPoint, fit: CGRect
    ) -> ViewerZoomState {
        guard delta > 0, fit.width > 0, fit.height > 0 else { return state }
        let oldScale = clampedScale(state.scale)
        let newScale = clampedScale(oldScale * delta)
        let factor = newScale / oldScale
        // Anchor invariance in center form: with the video rect's center
        // c = fitCenter + offset, the anchor's center-relative position
        // scales by `factor`, so cNew = anchor - (anchor - cOld) * factor.
        let fitCenter = CGPoint(x: fit.midX, y: fit.midY)
        let oldCenter = CGPoint(x: fitCenter.x + state.offset.x, y: fitCenter.y + state.offset.y)
        let newCenter = CGPoint(
            x: anchor.x - (anchor.x - oldCenter.x) * factor,
            y: anchor.y - (anchor.y - oldCenter.y) * factor)
        let offset = CGPoint(x: newCenter.x - fitCenter.x, y: newCenter.y - fitCenter.y)
        return ViewerZoomState(
            scale: newScale,
            offset: clampedOffset(offset, scale: newScale, fit: fit))
    }

    /// State after panning the content by `delta`, in viewport points. A
    /// positive `width` moves the video right; a positive `height` moves it
    /// up (non-flipped AppKit coordinates). No-ops at fit — the offset
    /// clamp collapses to zero when there is nothing to pan over.
    static func panned(state: ViewerZoomState, by delta: CGSize, fit: CGRect) -> ViewerZoomState {
        guard fit.width > 0, fit.height > 0 else { return state }
        let scale = clampedScale(state.scale)
        let offset = CGPoint(x: state.offset.x + delta.width, y: state.offset.y + delta.height)
        return ViewerZoomState(scale: scale, offset: clampedOffset(offset, scale: scale, fit: fit))
    }

    /// Double-tap (smart-magnify) toggle: zoomed in → reset to fit; at fit
    /// → jump to ``smartMagnifyScale`` anchored at the tap point.
    static func smartMagnifyToggled(
        state: ViewerZoomState, anchor: CGPoint, fit: CGRect
    ) -> ViewerZoomState {
        if state.scale > minScale {
            return ViewerZoomState()
        }
        return zoomed(state: ViewerZoomState(), by: smartMagnifyScale, anchor: anchor, fit: fit)
    }

    // MARK: - Clamps

    private static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    /// Keep the zoomed rect covering the fit rect on both axes: the zoomed
    /// size is `fit.size × scale ≥ fit.size`, so the center may stray at
    /// most half the size difference from the fit center before an edge
    /// would detach and expose a letterbox gap.
    private static func clampedOffset(_ offset: CGPoint, scale: CGFloat, fit: CGRect) -> CGPoint {
        let maxX = (scale - 1) * fit.width / 2
        let maxY = (scale - 1) * fit.height / 2
        return CGPoint(
            x: min(max(offset.x, -maxX), maxX),
            y: min(max(offset.y, -maxY), maxY))
    }
}
