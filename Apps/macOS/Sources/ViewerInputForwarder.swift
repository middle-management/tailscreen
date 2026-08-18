import Foundation

/// Ships captured remote-control input to the sharer **in the order it was
/// captured**.
///
/// `RemoteControlInputView` fires on the main actor; the send path
/// (`TailscaleScreenShareClient.sendInputEvent`) is `async` and serializes on
/// a writer actor. Bridging the two with one detached `Task` per event —
/// which is what this replaced — hands the runtime N independent tasks racing
/// for the same actor, and Swift promises nothing about which arrives first.
/// The failure that produces is not a dropped event but a REORDERED one: a
/// `mouseUp` overtaking its `mouseDown` leaves a button held down on somebody
/// else's Mac until the grant is revoked, and a `keyUp` overtaking its
/// `keyDown` does the same to a key. Both are far worse than the click that
/// was supposed to happen not happening.
///
/// So events go through one `AsyncStream` drained by a **single** consumer
/// that awaits each send in turn: one producer, one consumer, capture order
/// preserved end to end. The GTK viewer's `InputForwarder` is the same shape
/// for the same reason, and `ViewerBackChannel.sendInputEvent` states the
/// contract both of them satisfy.
@MainActor
final class ViewerInputForwarder {
    private let stream: AsyncStream<InputEvent>
    private let continuation: AsyncStream<InputEvent>.Continuation
    private let send: @MainActor (InputEvent) async -> Void
    private var drainTask: Task<Void, Never>?

    /// - Parameter send: performs one send. Called serially, one await at a
    ///   time; resolve the live connection inside it so the forwarder keeps
    ///   working across a back-channel reconnect.
    init(send: @escaping @MainActor (InputEvent) async -> Void) {
        self.send = send
        var cont: AsyncStream<InputEvent>.Continuation!
        // Unbounded on purpose: dropping the oldest could drop a `mouseUp` or
        // `keyUp` and strand a button/key held on the sharer. Flood control
        // belongs upstream, where it can be selective — the capture view
        // throttles `mouseMove` (the only coalescable event) and the sharer's
        // injector coalesces runs of them per drain.
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    deinit {
        // Synchronous cleanup only — no `Task { … self … }` in `deinit`.
        // Finishing the stream ends the drain loop on its own.
        continuation.finish()
    }

    /// Submit one captured event. Order of `submit` calls is the order the
    /// sharer sees.
    func submit(_ event: InputEvent) {
        startDrainingIfNeeded()
        continuation.yield(event)
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        let stream = self.stream
        let send = self.send
        drainTask = Task {
            // One consumer, one await at a time → send order == capture order.
            for await event in stream {
                await send(event)
            }
        }
    }
}
