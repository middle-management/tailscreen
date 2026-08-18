import Foundation

/// Ships things to the sharer over the viewer's TCP back-channel **in the
/// order they were produced**.
///
/// The producers (`RemoteControlInputView`, `AnnotationCanvasModel`) fire on
/// the main actor; the send path (`TailscaleScreenShareClient.sendInputEvent`
/// / `sendAnnotationOp`) is `async` and serializes on a writer actor.
/// Bridging the two with one detached `Task` per item — which is what this
/// replaced — hands the runtime N independent tasks racing for that actor,
/// and Swift promises nothing about which arrives first.
///
/// What that costs is not a dropped item but a REORDERED one, and both
/// payloads on this channel are sequences rather than independent events:
///
///   - Input: a `mouseUp` overtaking its `mouseDown` leaves a button held
///     down on somebody else's Mac until the grant is revoked, and a `keyUp`
///     overtaking its `keyDown` does the same to a key. Both are far worse
///     than the click that was supposed to happen not happening.
///   - Annotations: `.undo(X)` only means anything to a peer that already has
///     `.add(X)`. Overtake it and the undo is dropped as an unknown id, so
///     the stroke stays on the sharer's screen — and on every other viewer's,
///     since the sharer relays it — for the rest of the share, with nothing
///     left that can remove it.
///
/// So items go through one `AsyncStream` drained by a **single** consumer
/// that awaits each send in turn: one producer, one consumer, production
/// order preserved end to end. The GTK viewer's `InputForwarder` /
/// `AnnotationForwarder` and the WinUI viewer's `Outbound` queue are the same
/// shape for the same reason, and `ViewerBackChannel.sendInputEvent` states
/// the contract all of them satisfy. The sharer's fan-out side has its own
/// (`TailscaleScreenShareServer.enqueueAnnotationBroadcast`), because the
/// relay to *other* viewers can invert the same pair independently.
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
        // Unbounded on purpose: dropping the oldest could drop a `mouseUp`,
        // a `keyUp`, or the `.add` a later `.undo` refers to — the exact
        // failures this type exists to prevent. Flood control belongs
        // upstream, where it can be selective: the capture view throttles
        // `mouseMove` (the only coalescable event) and the sharer's injector
        // coalesces runs of them per drain.
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
