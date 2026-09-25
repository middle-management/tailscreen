import Foundation
import TailscreenProtocol

/// Bounded hand-off between the task that reads the UDP socket and the
/// `@MainActor` run loop that feeds `ViewerPipeline`.
///
/// Why: the run loop used to call `recv` itself on the MainActor (the UI
/// thread on both swift-cross-ui hosts), making inbound rate a function of UI
/// responsiveness — measured at 15.6 datagrams/s against a sharer sending
/// hundreds, ~96% loss, blank window. Moving the socket off the actor removes
/// that coupling.
///
/// Bounded so overflow can't grow unbounded in this process; drops the OLDEST
/// datagram, since stale packets ahead of fresh ones just add latency.
///
/// A non-zero `droppedCount` means the *consumer* can't keep up — a
/// different problem from the socket ceiling this replaces.
///
/// Not an `actor`: the MainActor side needs a synchronous drain to keep its
/// own tick cadence; `await`ing an actor would reintroduce a suspension per pass.
final class DatagramInbox: Sendable {
    struct Datagram: Sendable {
        let payload: Data
        let from: String
    }

    /// Live datagrams held before overflow starts dropping. ~2048 × 1200B ≈
    /// 2.5MB worst case, about five seconds of a healthy stream.
    static let defaultCapacity = 2048

    private struct State {
        /// Moving `head` rather than `removeFirst`, which is O(n) per call
        /// and would be on the hot path for every overflow drop.
        var storage: [Datagram] = []
        var head = 0
        var dropped = 0
        var closed = false

        var count: Int { storage.count - head }
    }

    private let capacity: Int
    private let state = Guarded(State())

    init(capacity: Int = DatagramInbox.defaultCapacity) {
        self.capacity = capacity
    }

    /// Enqueue one datagram. Called from the receive task.
    func push(_ datagram: Datagram) {
        state.withLock { s in
            guard !s.closed else { return }
            if s.count >= capacity {
                s.head += 1
                s.dropped += 1
            }
            s.storage.append(datagram)
            // Reclaim the consumed prefix past one capacity's worth —
            // amortized O(1), covers a consumer that only partially keeps up.
            if s.head > capacity {
                s.storage.removeFirst(s.head)
                s.head = 0
            }
        }
    }

    /// Take up to `limit` datagrams in arrival order. Called from the MainActor
    /// loop; returns an empty array when nothing is queued.
    func drain(max limit: Int) -> [Datagram] {
        state.withLock { s in
            let available = s.count
            guard available > 0, limit > 0 else { return [] }
            let take = min(limit, available)
            let out = Array(s.storage[s.head..<(s.head + take)])
            s.head += take
            if s.head == s.storage.count {
                s.storage.removeAll(keepingCapacity: true)
                s.head = 0
            }
            return out
        }
    }

    /// Datagrams discarded on overflow since the session began.
    var droppedCount: Int {
        state.withLock { $0.dropped }
    }

    /// Live queue depth, for diagnostics.
    var depth: Int {
        state.withLock { $0.count }
    }

    /// Refuse further pushes and release what's held. The receive task may
    /// still be unwinding its own `recv` when the loop exits; this makes its
    /// last push a no-op instead of a leak.
    func close() {
        state.withLock { s in
            s.closed = true
            s.storage.removeAll()
            s.head = 0
        }
    }
}

/// One-way flag the socket-reading task raises when its receive-error budget
/// is spent (see `TsnetTransport.receiveFailureIsFatal`), read synchronously
/// by the `@MainActor` run loop — same cross-task hand-off shape as
/// `DatagramInbox`, for the same suspension-free-read reason.
///
/// Without this, a dead socket's `catch { continue }` never surfaced: the loop
/// kept ticking against an inbox that would never fill again, freezing the
/// viewer on its last frame with a live-looking UI.
final class ReceiveFailureFlag: Sendable {
    private let raised = Guarded(false)

    /// Called from the receive task, once, when the socket is declared dead.
    func raise() {
        raised.withLock { $0 = true }
    }

    /// Polled by the run loop.
    var isRaised: Bool {
        raised.withLock { $0 }
    }
}
