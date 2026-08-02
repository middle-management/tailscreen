import Foundation
import TailscreenViewer

/// `VideoSink` that stashes the latest frame into a `FrameStore` for the
/// `GtkVideoView` to draw. The portable seam is codec-agnostic
/// (`any DecodedFrame`); this GL sink only understands CPU I420, so a
/// non-`DecodedVideoFrame` is dropped (it can't arise — the paired
/// `FFmpegVideoDecoder` only emits that type).
public final class GtkVideoSink: VideoSink, @unchecked Sendable {
    private let store: FrameStore
    private let uiState: ViewerUIState?
    // Touched only on `present`, which the session drives serially.
    private var announcedVideo = false
    // fps accounting over a ~1 s window (present is called serially).
    private var windowStartNs: UInt64 = 0
    private var framesInWindow = 0

    public init(store: FrameStore, uiState: ViewerUIState? = nil) {
        self.store = store
        self.uiState = uiState
    }

    /// Reset the first-frame latch + fps window so a REUSED sink re-announces
    /// video on the next session (the sink outlives a single viewing session).
    /// Call on the session-driving context before a new `run`.
    public func resetForNewSession() {
        announcedVideo = false
        windowStartNs = 0
        framesInWindow = 0
    }

    public func present(_ frame: any DecodedFrame) {
        guard let frame = frame as? DecodedVideoFrame else { return }
        // `set` stores the frame (lock-guarded) and requests a GLArea repaint.
        // The repaint is marshalled onto the GTK main thread inside CGtkVideo
        // (g_idle_add), so `present` is safe to call from any thread — it does
        // not itself touch GTK. The transport currently drives it on the main
        // actor, but this does not depend on that.
        store.set(frame)
        if !announcedVideo {
            announcedVideo = true
            uiState?.markVideoFlowing()  // hides the connecting placard
            uiState?.post(sessionPhase: .viewing)
        }
        // fps HUD: count frames per ~1 s window; publish fps + resolution.
        let now = DispatchTime.now().uptimeNanoseconds
        if windowStartNs == 0 { windowStartNs = now }
        framesInWindow += 1
        let elapsed = now &- windowStartNs
        if elapsed >= 1_000_000_000 {
            let fps = Int((Double(framesInWindow) * 1_000_000_000.0 / Double(elapsed)).rounded())
            uiState?.post(fps: fps, width: frame.width, height: frame.height)
            windowStartNs = now
            framesInWindow = 0
        }
    }
}
