import Foundation
import TailscreenViewer

/// The GTK viewer's `VideoSink`: the portable `FrameStoreVideoSink` wired to
/// this app's `ViewerUIState`.
///
/// Everything that used to be here — the `DecodedVideoFrame` guard, the
/// first-frame latch, the ~1 s fps window — moved to the portable sink when
/// the Windows viewer turned out to need the identical thing. What is left is
/// the part that is genuinely GTK's: which UI state the two callbacks poke.
///
/// The type survives rather than the call site constructing the portable sink
/// directly because `resetForNewSession` and the `uiState:` initializer are
/// what the app's session loop reads as.
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
            onStats: { width, height, fps in
                uiState?.post(fps: fps, width: width, height: height)
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
