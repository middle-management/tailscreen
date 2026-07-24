import Foundation
import TailscreenProtocol
import TailscreenViewerTsnet

/// Relays finalized local annotation ops (`AnnotationStore.onLocalOp`) to the
/// sharer over the `ViewerBackChannel`, funnelling them through ONE `AsyncStream`
/// drained by a single consumer so add/undo/clear order is preserved on the wire
/// (the same ordering discipline the input forwarder uses). The channel is
/// re-bindable: a new session's channel replaces the old one, and the single
/// drain loop reads whichever is current — so annotations keep working after a
/// back-to-picker reconnect.
@MainActor
final class AnnotationForwarder {
    private var channel: ViewerBackChannel?
    private let stream: AsyncStream<AnnotationOp>
    private let continuation: AsyncStream<AnnotationOp>.Continuation
    private var drainStarted = false

    init() {
        var cont: AsyncStream<AnnotationOp>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    /// Bind (or rebind) the current session's back-channel. Safe from any thread.
    nonisolated func attach(_ channel: ViewerBackChannel) {
        Task { @MainActor in
            self.channel = channel
            self.startDraining()
        }
    }

    private func startDraining() {
        guard !drainStarted else { return }
        drainStarted = true
        let stream = self.stream
        Task { [weak self] in
            for await op in stream {
                guard let channel = self?.channel else { continue }
                await channel.sendAnnotation(op)
            }
        }
    }

    /// Submit a local op for relay. Safe to call from the GTK main thread (where
    /// `AnnotationStore.onLocalOp` fires).
    nonisolated func submit(_ op: AnnotationOp) {
        MainActor.assumeIsolated { continuation.yield(op) }
    }
}
