import Foundation
import TailscreenViewer

/// The GTK viewer's `VideoSink`: wraps the portable `FrameStoreVideoSink`,
/// wiring its callbacks to this app's `ViewerUIState`.
public final class GtkVideoSink: VideoSink, @unchecked Sendable {
    private let sink: FrameStoreVideoSink

    public init(store: FrameStore, uiState: ViewerUIState? = nil) {
        sink = FrameStoreVideoSink(
            store: store,
            // Hides the connecting placard and moves the session to viewing.
            onFirstFrame: {
                uiState?.markVideoFlowing()
                uiState?.post(sessionPhase: .viewing)
            },
            onStats: { width, height, fps, color in
                uiState?.post(fps: fps, width: width, height: height, color: color)
            })
        // No `onFrame`: the repaint is requested inside `FrameStore.set`, and
        // CGtkVideo marshals it onto the GTK main thread with `g_idle_add`, so
        // `present` stays safe to call from any thread.
    }

    /// Reset the first-frame latch + fps window so a REUSED sink re-announces
    /// video on the next session (the sink outlives a single viewing session).
    /// Call on the session-driving context before a new `run`.
    public func resetForNewSession() {
        sink.resetForNewSession()
    }

    public func present(_ frame: any DecodedFrame) {
        sink.present(frame)
    }
}
