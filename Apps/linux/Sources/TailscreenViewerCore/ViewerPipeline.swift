import Foundation
import TailscreenProtocol
import TailscreenViewer

/// Assembles a portable `ViewerSession` with a concrete decoder and sinks, and
/// gives the host (the tsnet CLI, or a test) one object to drive: `start()`,
/// then `receive(_:)` per inbound datagram and `tick(nowNs:)` on a clock.
///
/// It's deliberately thin — all the receive-side logic lives in `ViewerSession`
/// — but it (a) fixes the wiring in one place both `main` and the integration
/// test share, and (b) retains the concrete sinks so the host can reach
/// backend-specific affordances (e.g. polling the host window for a close).
///
/// Not `Sendable`: like `ViewerSession`, the host must serialize `start` /
/// `receive` / `tick` onto one queue.
public final class ViewerPipeline {
    /// The portable session doing the real work. Exposed so the host can read
    /// negotiated state (`assignedSSRC`, `serverCaps`, `isStopped`, …).
    public let session: ViewerSession

    public init(
        caps: ScreenShareCaps,
        decoder: VideoDecoding,
        videoSink: VideoSink,
        audioSink: AudioSink? = nil,
        onControlToSend: @escaping (Data) -> Void
    ) {
        self.session = ViewerSession(
            caps: caps,
            decoder: decoder,
            videoSink: videoSink,
            audioSink: audioSink,
            onControlToSend: onControlToSend
        )
    }

    /// Emit the HELLO advertising our caps (host ships the bytes to the sharer).
    public func start() { session.start() }

    /// Feed one inbound UDP datagram.
    public func receive(_ data: Data) { session.receiveRTP(data) }

    /// Advance the clock: ages NACK gaps and emits the ~1 Hz receiver report.
    public func tick(nowNs: UInt64) { session.tick(nowNs: nowNs) }

    /// True once the sharer said goodbye / declined us — the host should stop.
    public var isStopped: Bool { session.isStopped }
}
