import Foundation

import protocol TailscreenViewer.DecodedFrame
import struct TailscreenViewer.DecodedVideoFrame
import class TailscreenViewer.FrameStore
import protocol TailscreenViewer.VideoSink

/// `VideoSink` that parks the latest decoded frame in a `FrameStore` for
/// `WinUIVideoView` to blit, and pokes the UI so it redraws.
///
/// Mirrors `GtkVideoSink` deliberately — same seam, same store, same
/// drop-a-non-I420-frame rule. The only difference is what wakes the renderer:
/// GTK has `g_idle_add` inside its C shim, while here the app's observable
/// state is what makes swift-cross-ui call `updateWinUIElement`.
///
/// `@unchecked Sendable` on the same terms as the GTK sink: `FrameStore` is
/// internally locked, and `onFrame` is expected to marshal if it needs to. The
/// transport drives `present` on the main actor today, which on this backend is
/// the UI thread, but nothing here relies on that.
final class WindowsVideoSink: VideoSink, @unchecked Sendable {
    private let store: FrameStore
    private let onFrame: @Sendable () -> Void

    init(store: FrameStore, onFrame: @escaping @Sendable () -> Void) {
        self.store = store
        self.onFrame = onFrame
    }

    func present(_ frame: any DecodedFrame) {
        // The portable seam is codec-agnostic; this CPU blit path only
        // understands I420, and the paired FFmpeg decoder only emits that.
        guard let frame = frame as? DecodedVideoFrame else { return }
        store.set(frame)
        onFrame()
    }
}
