#if canImport(CoreGraphics)
import CoreGraphics
#else
// On non-Apple platforms the CG geometry types (CGFloat/CGPoint/CGSize/
// CGRect) come from swift-corelibs-foundation.
import Foundation
#endif

/// Continuous content-zoom state for the viewer window. `scale == 1` means
/// the video sits exactly at its aspect-fit rect; larger scales magnify the
/// video about the fit rect's center, shifted by `offset`. Pure value type —
/// all geometry lives in ``ViewerZoomMath`` so the decision math is
/// CI-testable without AppKit.
public struct ViewerZoomState: Equatable {
    public init(scale: CGFloat = 1.0, offset: CGPoint = .zero) {
        self.scale = scale
        self.offset = offset
    }

    /// Content magnification relative to the aspect-fit rect. Every
    /// transition function clamps it to
    /// `ViewerZoomMath.minScale...ViewerZoomMath.maxScale`; 1.0 == fit.
    public var scale: CGFloat = 1.0
    /// Pan offset of the zoomed video's center from the fit rect's center,
    /// in viewport points. Always `.zero` at scale 1.
    public var offset: CGPoint = .zero

    /// True when the content is magnified past aspect-fit — the "am I
    /// zoomed" predicate gesture handling branches on.
    public var isZoomedIn: Bool { scale > ViewerZoomMath.minScale }
}

/// Pure zoom/pan geometry for the viewer's content zoom. The host view
/// (`AspectFitHostView`) feeds gesture deltas in and lays out both the
/// metal layer and the annotation overlay from the single rect
/// ``videoRect(fit:state:)`` returns — their congruence is what keeps
/// annotation coordinates video-relative at any zoom. Extracted per
/// CLAUDE.md's extract-the-decision pattern; covered by
/// `ViewerZoomMathTests` on CI.
public enum ViewerZoomMath {
    /// Fully zoomed out == aspect-fit. Zooming below fit is not supported;
    /// the window-sizing presets (⌘0 / ⌘- / ⌘+) cover "smaller than fit".
    public static let minScale: CGFloat = 1.0
    /// Preview-style ceiling — deep enough to read small text on a 5K
    /// share squeezed into a laptop-sized viewer window.
    public static let maxScale: CGFloat = 8.0
    /// Target scale for the double-tap (smart-magnify) toggle.
    public static let smartMagnifyScale: CGFloat = 2.0
    /// Multiplicative step for the View-menu Zoom In item; Zoom Out uses
    /// its reciprocal.
    public static let menuZoomStep: CGFloat = 1.25
    /// Conservative ceiling on the zoomed content's pixel extent. The
    /// annotation overlay is a layer-backed NSHostingView framed at the
    /// zoomed rect; Core Animation textures top out around 16384 px per
    /// axis, and exceeding that blanks the layer.
    public static let safeMaxContentPixels: CGFloat = 16_384

    /// The largest scale the current fit rect can support without the
    /// zoomed rect's backing store exceeding ``safeMaxContentPixels`` on
    /// its longer axis. Clamped to `minScale...maxScale`; a degenerate
    /// fit imposes no cap.
    public static func effectiveMaxScale(fit: CGRect, backingScale: CGFloat) -> CGFloat {
        guard fit.width > 0, fit.height > 0 else { return maxScale }
        let cap = safeMaxContentPixels / (max(fit.width, fit.height) * max(backingScale, 1))
        return max(minScale, min(maxScale, cap))
    }

    /// The rect the video (and the congruent annotation overlay) should
    /// occupy: `fit` scaled by `state.scale` about its own center, then
    /// shifted by `state.offset`. The offset is re-clamped here so a stale
    /// state (e.g. after a window resize shrank `fit`) can never open a
    /// gap between the video's edge and the fit rect's edge.
    public static func videoRect(fit: CGRect, state: ViewerZoomState) -> CGRect {
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
    /// offset clamps. Callers pass `maxScale` from
    /// ``effectiveMaxScale(fit:backingScale:)`` to stay under the texture
    /// limit; the default is the static ceiling.
    public static func zoomed(
        state: ViewerZoomState, by delta: CGFloat, anchor: CGPoint, fit: CGRect,
        maxScale: CGFloat = ViewerZoomMath.maxScale
    ) -> ViewerZoomState {
        guard delta > 0, fit.width > 0, fit.height > 0 else { return state }
        let oldScale = clampedScale(state.scale)
        let newScale = min(max(oldScale * delta, minScale), maxScale)
        let factor = newScale / oldScale
        // Re-clamp the incoming offset against the *current* fit first —
        // a window resize between gestures can leave `state.offset` stale
        // (legal for the old fit only), and anchoring against the stale
        // center would make the first gesture jump away from the rect
        // `videoRect` is actually displaying.
        let oldOffset = clampedOffset(state.offset, scale: oldScale, fit: fit)
        // Anchor invariance in center form: with the video rect's center
        // c = fitCenter + offset, the anchor's center-relative position
        // scales by `factor`, so cNew = anchor - (anchor - cOld) * factor.
        let fitCenter = CGPoint(x: fit.midX, y: fit.midY)
        let oldCenter = CGPoint(x: fitCenter.x + oldOffset.x, y: fitCenter.y + oldOffset.y)
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
    /// clamp collapses to zero when there is nothing to pan over. The
    /// scale passes through unclamped: panning never changes it, every
    /// producer already clamps it, and `videoRect`'s defensive re-clamp
    /// remains the single stale-state barrier.
    public static func panned(state: ViewerZoomState, by delta: CGSize, fit: CGRect) -> ViewerZoomState {
        guard fit.width > 0, fit.height > 0 else { return state }
        let offset = CGPoint(x: state.offset.x + delta.width, y: state.offset.y + delta.height)
        return ViewerZoomState(
            scale: state.scale,
            offset: clampedOffset(offset, scale: state.scale, fit: fit))
    }

    /// Double-tap (smart-magnify) toggle: zoomed in → reset to fit; at fit
    /// → jump to ``smartMagnifyScale`` anchored at the tap point (capped
    /// at the caller's `maxScale`).
    public static func smartMagnifyToggled(
        state: ViewerZoomState, anchor: CGPoint, fit: CGRect,
        maxScale: CGFloat = ViewerZoomMath.maxScale
    ) -> ViewerZoomState {
        if state.isZoomedIn {
            return ViewerZoomState()
        }
        return zoomed(
            state: ViewerZoomState(), by: smartMagnifyScale, anchor: anchor, fit: fit,
            maxScale: maxScale)
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
