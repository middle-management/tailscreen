import Foundation
import TailscreenProtocol
import TailscreenViewerGtk
import TailscreenViewerTsnet

/// Bridges captured GTK input (`GtkVideoView.onInputEvent`, fired on the GTK
/// main thread) to the sharer over the `ViewerBackChannel`, applying two rules:
///
///  1. **Gate.** Events are forwarded only while `ViewerUIState.forwardsRemoteInput`
///     — a grant is live and no annotation tool is armed. Before a grant, or
///     after a revoke/release, captured input is dropped, so moving the mouse
///     over the video never leaks input to the sharer. That property is also
///     what the video view's wheel handler asks before scrolling the sharer
///     instead of zooming locally, which is why the rule is spelled there
///     rather than here. (The Windows viewer's `forwardsInput` is the same
///     rule; the precedence is load-bearing, see plans/platform-alignment.md.)
///
///  2. **Order.** The `ViewerBackChannel` actor preserves order only for calls
///     that reach it in order (see its `sendInputEvent` ORDERING CONTRACT). So
///     captured events are funnelled through **one** `AsyncStream` and drained
///     by a **single** consumer task that awaits each `sendInputEvent` in turn —
///     never one detached `Task` per event, which could invert a down/up pair.
///
/// The back-channel arrives asynchronously (once the transport dials the
/// sharer); until it attaches, gated events are simply discarded.
@MainActor
final class InputForwarder {
    private let ui: ViewerUIState
    private let stream: AsyncStream<InputEvent>
    private let continuation: AsyncStream<InputEvent>.Continuation
    private var drainTask: Task<Void, Never>?

    init(ui: ViewerUIState) {
        self.ui = ui
        var cont: AsyncStream<InputEvent>.Continuation!
        // Unbounded on purpose: dropping the oldest could drop a `mouseUp`/
        // `keyUp` and strand a button/key held on the sharer. Input is user-
        // paced, so the queue stays small; coalescing high-frequency
        // `mouseMove`s (as the mac viewer does) is a noted follow-up.
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    /// Called from the transport's `onBackChannelReady` (any thread). Hops to
    /// the main actor to stash the channel and start the single drain consumer.
    nonisolated func attach(_ channel: ViewerBackChannel) {
        Task { @MainActor in self.startDraining(channel) }
    }

    private func startDraining(_ channel: ViewerBackChannel) {
        guard drainTask == nil else { return }
        let stream = self.stream
        drainTask = Task {
            // One consumer, one await at a time → send order == capture order.
            for await event in stream {
                await channel.sendInputEvent(event)
            }
        }
    }

    /// Submit one captured event. Safe to call from the GTK main thread (where
    /// the event controllers fire); the gate reads `controlState` on that same
    /// main thread, so it never races the state machine's writes.
    nonisolated func submit(_ event: InputEvent) {
        MainActor.assumeIsolated {
            guard ui.forwardsRemoteInput else { return }
            continuation.yield(event)
        }
    }
}
