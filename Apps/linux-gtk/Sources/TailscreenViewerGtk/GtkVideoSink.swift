import Foundation
import TailscreenViewer

/// `VideoSink` that stashes the latest frame into a `FrameStore` for the
/// `GtkVideoView` to draw. The portable seam is codec-agnostic
/// (`any DecodedFrame`); this GL sink only understands CPU I420, so a
/// non-`DecodedVideoFrame` is dropped (it can't arise — the paired
/// `FFmpegVideoDecoder` only emits that type).
public final class GtkVideoSink: VideoSink, @unchecked Sendable {
    private let store: FrameStore

    public init(store: FrameStore) {
        self.store = store
    }

    public func present(_ frame: any DecodedFrame) {
        guard let frame = frame as? DecodedVideoFrame else { return }
        // `set` stores the frame (lock-guarded) and requests a GLArea repaint.
        // The repaint is marshalled onto the GTK main thread inside CGtkVideo
        // (g_idle_add), so `present` is safe to call from any thread — it does
        // not itself touch GTK. The transport currently drives it on the main
        // actor, but this does not depend on that.
        store.set(frame)
    }
}
