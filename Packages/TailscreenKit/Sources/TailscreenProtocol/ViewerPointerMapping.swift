import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a pointer inside a viewer's video pane lands in the sharer's frame.
///
/// Shared because every viewer needs this arithmetic (GTK letterboxes in its
/// GL shader, WinUI via `Image.stretch = .uniform`, macOS via
/// `AspectFitHostView` — three mechanisms, one geometry). Getting it wrong
/// offsets every click by the letterbox bar, which reads as "remote control
/// is inaccurate" rather than a coordinate bug, and only shows up on panes
/// whose aspect differs from the video's.
public enum ViewerPointerMapping {
    /// Map a pane-space pointer position to normalized `[0, 1]` over the
    /// aspect-fit **video content rect** — letterbox bars excluded — origin
    /// top-left, the space `InputEvent`/`Annotation` use.
    ///
    /// Clamped so a position inside a letterbox bar lands on the nearest
    /// content edge; the sharer clamps identically (`ScreenRegion.point`).
    /// Ratio-based throughout, independent of display scaling.
    ///
    /// Grouped as three pairs, not six scalars: six positional `Double`s
    /// invite transposing a width and height at a call site, a mistake that
    /// compiles and produces the same silent offset this type prevents.
    public static func normalize(
        point: (x: Double, y: Double),
        paneSize: (width: Double, height: Double),
        videoSize: (width: Int, height: Int)
    ) -> (x: Double, y: Double) {
        guard paneSize.width > 0, paneSize.height > 0,
            videoSize.width > 0, videoSize.height > 0
        else {
            return (0, 0)
        }
        let content = fitRect(paneSize: paneSize, videoSize: videoSize)
        let nx = (point.x - Double(content.minX)) / Double(content.width)
        let ny = (point.y - Double(content.minY)) / Double(content.height)
        return (clampUnit(nx), clampUnit(ny))
    }

    /// The aspect-fit **content rect** the video occupies inside a pane of
    /// `paneSize`: centered, bars split evenly, in the pane's own coordinate
    /// space (orientation-agnostic, so y-down and y-up views both read it
    /// directly).
    ///
    /// Exposed as a rect (not just via `normalize`) because zoom anchoring,
    /// pan clamping (`ViewerZoomMath`'s `fit:`), and video-surface layout
    /// must all agree with pointer mapping about where the bars are, or a
    /// click lands in one place and zooms about another.
    ///
    /// Degenerate input (a pane or video dimension ≤ 0) returns the whole
    /// pane rect: nothing to letterbox against.
    public static func fitRect(
        paneSize: (width: Double, height: Double),
        videoSize: (width: Int, height: Int)
    ) -> CGRect {
        let paneWidth = paneSize.width
        let paneHeight = paneSize.height
        guard paneWidth > 0, paneHeight > 0, videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: CGFloat(paneWidth), height: CGFloat(paneHeight))
        }
        let paneAspect = paneWidth / paneHeight
        let frameAspect = Double(videoSize.width) / Double(videoSize.height)
        var contentWidth = paneWidth
        var contentHeight = paneHeight
        if frameAspect > paneAspect {
            contentHeight = paneWidth / frameAspect  // fit to width; bars top/bottom
        } else {
            contentWidth = paneHeight * frameAspect  // fit to height; bars left/right
        }
        return CGRect(
            x: CGFloat((paneWidth - contentWidth) / 2),
            y: CGFloat((paneHeight - contentHeight) / 2),
            width: CGFloat(contentWidth),
            height: CGFloat(contentHeight))
    }

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
