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
        store.set(frame)
        // L0b: marshal gtk_gl_area_queue_render onto the GTK main thread here so
        // frames arriving on the (off-main) transport thread repaint promptly.
        // In L0a the frame is set before the app runs, so the GLArea's first
        // realize-render shows it with no cross-thread hand-off.
    }
}
