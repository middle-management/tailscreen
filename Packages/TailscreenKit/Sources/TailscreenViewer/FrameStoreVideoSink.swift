import Foundation
import TailscreenProtocol

/// The `VideoSink` a CPU-blit renderer wants: park the latest decoded frame in
/// a `FrameStore`, poke the host to redraw, and report the stats HUD's numbers
/// when an fps window closes. Shared by the GTK and WinUI viewers, whose
/// callback needs differ but whose frame handling is identical.
///
/// The `as? DecodedVideoFrame` guard is not defensive habit: the sink seam is
/// codec-agnostic (`any DecodedFrame`) but a CPU blit understands only I420,
/// so an unexpected shape is dropped rather than misread or force-cast.
///
/// `@unchecked Sendable`: `FrameStore` is internally locked, and every
/// callback is expected to marshal onto the host's UI thread itself.
public final class FrameStoreVideoSink: VideoSink, @unchecked Sendable {
    private let store: FrameStore
    private let onFirstFrame: (@Sendable () -> Void)?
    private let onFrame: (@Sendable () -> Void)?
    private let onStats: (@Sendable (_ width: Int, _ height: Int, _ fps: Int, _ color: VideoColorInfo) -> Void)?
    private let clock: @Sendable () -> UInt64

    /// Touched only from `present`, which the session drives serially — no
    /// lock needed (same contract as `FrameRateCounter`).
    private var announcedFirstFrame = false
    private var frameRate = FrameRateCounter()

    /// - Parameters:
    ///   - onFirstFrame: fired once per session, before `onFrame`, for a host
    ///     with separate "video is flowing" state. Nil if not needed.
    ///   - onFrame: the redraw request, fired per frame. Nil if the store
    ///     already wakes its renderer (GTK does this in `FrameStore.set`).
    ///   - onStats: fired once per closed fps window (~1/s). `color` is the
    ///     closing frame's colour encoding, which explains a washed-out or
    ///     crushed picture that a viewer can't infer by eye.
    ///   - clock: injected so fps windowing is testable without sleeping.
    public init(
        store: FrameStore,
        onFirstFrame: (@Sendable () -> Void)? = nil,
        onFrame: (@Sendable () -> Void)? = nil,
        onStats:
            (@Sendable (_ width: Int, _ height: Int, _ fps: Int, _ color: VideoColorInfo) -> Void)? =
            nil,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.store = store
        self.onFirstFrame = onFirstFrame
        self.onFrame = onFrame
        self.onStats = onStats
        self.clock = clock
    }

    /// Forget the first-frame latch and the fps window before a new session
    /// (a sink outlives one viewing session on both hosts). Call before `run`.
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
            onStats?(frame.width, frame.height, fps, frame.colorInfo)
        }
    }
}
