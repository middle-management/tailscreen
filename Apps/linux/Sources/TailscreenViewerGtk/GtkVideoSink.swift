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
    // fps accounting over a ~1 s window (present is called serially). The
    // arithmetic moved to the portable tier when the Windows viewer needed the
    // identical thing — and gained tests, which caught that the old `0`
    // window-start sentinel is a legitimate timestamp.
    private var frameRate = FrameRateCounter()

    public init(store: FrameStore, uiState: ViewerUIState? = nil) {
        self.store = store
        self.uiState = uiState
    }

    /// Reset the first-frame latch + fps window so a REUSED sink re-announces
    /// video on the next session (the sink outlives a single viewing session).
    /// Call on the session-driving context before a new `run`.
    public func resetForNewSession() {
        announcedVideo = false
        frameRate.reset()
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
        // fps HUD: publish only when a window closes, which is what keeps this
        // off the per-frame path.
        if let fps = frameRate.record(nowNs: DispatchTime.now().uptimeNanoseconds) {
            uiState?.post(fps: fps, width: frame.width, height: frame.height)
        }
    }
}
