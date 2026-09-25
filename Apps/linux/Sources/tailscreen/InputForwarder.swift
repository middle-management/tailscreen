import Foundation
import TailscreenProtocol
import TailscreenViewerGtk
import TailscreenViewerTsnet

/// Bridges captured GTK input (`GtkVideoView.onInputEvent`) to the sharer over
/// the `ViewerBackChannel`, applying two rules:
///
///  1. **Gate.** Forwarded only while `ViewerUIState.forwardsRemoteInput` (grant
///     live, no annotation tool armed) — see that property for why the rule
///     lives there and not here.
///
///  2. **Order.** `ViewerBackChannel.sendInputEvent` only preserves order for
///     calls that reach it in order, so captured events funnel through ONE
///     `AsyncStream` drained by a single consumer — never a detached `Task`
///     per event, which could invert a down/up pair.
///
/// Gated events are discarded until the back-channel attaches.
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

    /// Safe to call from the GTK main thread (where the event controllers
    /// fire and the gate's state is also written, so no race).
    nonisolated func submit(_ event: InputEvent) {
        MainActor.assumeIsolated {
            guard ui.forwardsRemoteInput else { return }
            continuation.yield(event)
        }
    }
}
