import Foundation

/// Where a pointer inside a viewer's video pane lands in the sharer's frame.
///
/// One function, and it is here rather than in a host because **every** viewer
/// needs exactly this arithmetic and none of them can test it: the GTK viewer
/// letterboxes in its GL shader, the WinUI viewer letterboxes via
/// `Image.stretch = .uniform`, and macOS via `AspectFitHostView` — three
/// different mechanisms producing the same geometry, because aspect-fit is
/// aspect-fit.
///
/// Getting it wrong does not error. It offsets every click and every stroke by
/// the letterbox bar, which reads as "remote control is inaccurate" rather than
/// as a coordinate bug — and it is wrong only on panes whose aspect differs
/// from the video's, so a developer testing on a matching window sees nothing.
///
/// It lived in `TailscreenViewerCore.ViewerInputMapping` (Linux-only, since
/// that target pulls FFmpeg and ALSA) until the Windows viewer needed it. That
/// target still re-exposes it, so no GTK caller changed.
public enum ViewerPointerMapping {
    /// Map a pane-space pointer position to normalized `[0, 1]` over the
    /// aspect-fit **video content rect** — letterbox bars excluded — with the
    /// origin top-left, which is the space `InputEvent` and `Annotation` use.
    ///
    /// The result is clamped, so a position inside a letterbox bar lands on the
    /// nearest content edge rather than outside the frame. The sharer clamps
    /// identically (`ScreenRegion.point`), so this can never produce a click
    /// the sharer has to reject.
    ///
    /// Ratio-based throughout, so it is independent of display scaling: a
    /// HiDPI pane and its logical size share an aspect, which is the only thing
    /// that matters here.
    /// Grouped as three pairs rather than six scalars, which is what the
    /// arithmetic actually takes: a position, the pane it was in, and the frame
    /// being shown. Six positional `Double`s next to each other is also an
    /// invitation to transpose a width and a height at a call site — a mistake
    /// that compiles, and whose symptom is the same silent offset this whole
    /// type exists to prevent.
    public static func normalize(
        point: (x: Double, y: Double),
        paneSize: (width: Double, height: Double),
        videoSize: (width: Int, height: Int)
    ) -> (x: Double, y: Double) {
        let paneWidth = paneSize.width
        let paneHeight = paneSize.height
        guard paneWidth > 0, paneHeight > 0, videoSize.width > 0, videoSize.height > 0 else {
            return (0, 0)
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
        let offsetX = (paneWidth - contentWidth) / 2
        let offsetY = (paneHeight - contentHeight) / 2
        let nx = (point.x - offsetX) / contentWidth
        let ny = (point.y - offsetY) / contentHeight
        return (clampUnit(nx), clampUnit(ny))
    }

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
