import Foundation

/// The `VideoSink` a CPU-blit renderer wants: park the latest decoded frame in
/// a `FrameStore` for the host's view to draw, poke the host so it redraws, and
/// report the stats HUD's numbers when an fps window closes.
///
/// Both swift-cross-ui viewers had written this out, and their copies had
/// already drifted in the way copies do: the GTK one announced the first frame
/// (which is what hides its connecting placard) and the Windows one did not,
/// because Windows moves its session phase somewhere else. The differences are
/// all *callbacks*; the frame handling underneath is identical, down to the
/// `as? DecodedVideoFrame` guard and the reason for it.
///
/// **The guard is not defensive habit.** The portable sink seam is
/// codec-agnostic (`any DecodedFrame`) while a CPU blit path understands only
/// I420, so a frame of another shape is dropped rather than misread. It cannot
/// arise today — the `FFmpegVideoDecoder` both hosts pair this with emits only
/// `DecodedVideoFrame` — which is exactly why it must be a guard and not a
/// force-cast: the day a decoder emits something else, a dropped frame is a
/// visible stall and a crash is a bug report.
///
/// `@unchecked Sendable` on the terms the hosts already relied on: `FrameStore`
/// is internally locked, and every callback is expected to marshal onto the
/// host's UI thread if it needs to. The transport drives `present` on the main
/// actor today, but nothing here depends on that.
public final class FrameStoreVideoSink: VideoSink, @unchecked Sendable {
    private let store: FrameStore
    private let onFirstFrame: (@Sendable () -> Void)?
    private let onFrame: (@Sendable () -> Void)?
    private let onStats: (@Sendable (_ width: Int, _ height: Int, _ fps: Int) -> Void)?
    private let clock: @Sendable () -> UInt64

    /// Touched only from `present`, which the session drives serially — the
    /// same contract `FrameRateCounter` documents, and the reason neither of
    /// these needs a lock.
    private var announcedFirstFrame = false
    private var frameRate = FrameRateCounter()

    /// - Parameters:
    ///   - onFirstFrame: fired once per session, before `onFrame`, for a host
    ///     whose "video is flowing now" state is separate from its redraw. Nil
    ///     for a host that has no such state.
    ///   - onFrame: fired for every frame — the redraw request. Nil for a
    ///     backend whose store already wakes its renderer (the GTK shim does
    ///     this itself, inside `FrameStore.set`).
    ///   - onStats: fired only when an fps window closes, roughly once a
    ///     second. That is what keeps stats off the per-frame path.
    ///   - clock: injected so the fps windowing is testable without sleeping.
    public init(
        store: FrameStore,
        onFirstFrame: (@Sendable () -> Void)? = nil,
        onFrame: (@Sendable () -> Void)? = nil,
        onStats: (@Sendable (_ width: Int, _ height: Int, _ fps: Int) -> Void)? = nil,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.store = store
        self.onFirstFrame = onFirstFrame
        self.onFrame = onFrame
        self.onStats = onStats
        self.clock = clock
    }

    /// Forget the first-frame latch and the fps window before a new session.
    ///
    /// A sink outlives one viewing session on both hosts, so without this the
    /// first frame of the next one closes a window opened during the previous
    /// — reporting a fraction of an fps across the idle gap between them — and
    /// a reused sink never re-announces video, leaving the connecting placard
    /// up over a stream that is running.
    ///
    /// Call it on the session-driving context before a new `run`.
    public func resetForNewSession() {
        announcedFirstFrame = false
        frameRate.reset()
    }

    public func present(_ frame: any DecodedFrame) {
        guard let frame = frame as? DecodedVideoFrame else { return }
        store.set(frame)
        if !announcedFirstFrame {
            announcedFirstFrame = true
            onFirstFrame?()
        }
        onFrame?()
        if let fps = frameRate.record(nowNs: clock()) {
            onStats?(frame.width, frame.height, fps)
        }
    }
}
