import Foundation

/// Ships things to the sharer over the viewer's TCP back-channel **in the
/// order they were produced**.
///
/// A detached `Task` per item (the prior approach) hands the runtime N
/// independent tasks racing for the send path's writer actor, with no
/// ordering guarantee. Reordering, not dropping, is the failure mode, and
/// both payloads here are sequences: a `mouseUp` overtaking its `mouseDown`
/// leaves a button held down until the grant is revoked; `.undo(X)`
/// overtaking `.add(X)` is dropped as an unknown id, leaving the stroke
/// permanently on screen.
///
/// So items go through one `AsyncStream` drained by a single consumer that
/// awaits each send in turn. The GTK `InputForwarder`/`AnnotationForwarder`
/// and WinUI `Outbound` queue are the same shape; `ViewerBackChannel.sendInputEvent`
/// states the contract. The sharer's fan-out side has its own
/// (`TailscaleScreenShareServer.enqueueAnnotationBroadcast`), since relay to
/// other viewers can invert the pair independently.
@MainActor
final class OrderedOutbox<Element: Sendable> {
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let send: @MainActor (Element) async -> Void
    private var drainTask: Task<Void, Never>?

    /// - Parameter send: performs one send. Called serially, one await at a
    ///   time; resolve the live connection inside it so the outbox keeps
    ///   working across a back-channel reconnect.
    init(send: @escaping @MainActor (Element) async -> Void) {
        self.send = send
        // Unbounded on purpose: dropping the oldest could drop a `mouseUp` or
        // the `.add` a later `.undo` refers to. Flood control belongs
        // upstream (mouseMove throttling/coalescing).
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        // Synchronous cleanup only — no `Task { … self … }` in `deinit`.
        // Finishing the stream ends the drain loop on its own.
        continuation.finish()
    }

    /// Submit one item. The order of `submit` calls is the order the sharer
    /// sees.
    func submit(_ element: Element) {
        startDrainingIfNeeded()
        continuation.yield(element)
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        let stream = self.stream
        let send = self.send
        drainTask = Task {
            // One consumer, one await at a time → send order == submit order.
            for await element in stream {
                await send(element)
            }
        }
    }
}
