import Foundation
import Synchronization

/// Bounded hand-off between the task that reads the UDP socket and the
/// `@MainActor` run loop that feeds `ViewerPipeline`.
///
/// WHY THIS EXISTS: the run loop used to call `recv` itself, on the MainActor,
/// which on both swift-cross-ui hosts is the UI thread. That made the inbound
/// packet rate a function of how fast the UI could get back around the loop —
/// measured at 15.6 datagrams/s on the Windows viewer against a sharer sending
/// several hundred, so ~96% of the stream overflowed the socket buffer and the
/// window stayed blank. Draining harder per pass (the previous change) raises
/// that ceiling; moving the socket off the actor removes the coupling, so a
/// busy or janky UI can no longer cost packets.
///
/// The queue is the whole point: it decouples arrival from consumption, and it
/// is bounded because an unbounded one just moves an overflow the OS used to
/// absorb into this process, where it grows until something dies. Overflow
/// drops the OLDEST datagram — for RTP, holding stale packets in front of
/// fresh ones adds latency to the fresh ones and helps nobody, and the
/// reorder buffer treats either choice as loss.
///
/// A non-zero `droppedCount` means the *consumer* can't keep up (decode, or
/// the actor being busy), which is a different problem from the socket ceiling
/// this replaces — and the reason the count is reported rather than inferred.
///
/// Not an `actor`: the MainActor side needs a *synchronous* drain so it can
/// service the queue and still own its tick cadence, and `await`ing an actor
/// from the loop would reintroduce a suspension per pass.
final class DatagramInbox: Sendable {
    struct Datagram: Sendable {
        let payload: Data
        let from: String
    }

    /// Live datagrams held before overflow starts dropping. ~2048 × 1200 B ≈
    /// 2.5 MB worst case, and about five seconds of a healthy stream — deep
    /// enough to ride out a UI hitch, shallow enough that a consumer which has
    /// genuinely stopped can't balloon the process.
    static let defaultCapacity = 2048

    private struct State {
        /// Storage with a moving `head` rather than `removeFirst`, which is O(n)
        /// per call and would be on the hot path for every overflow drop.
        var storage: [Datagram] = []
        var head = 0
        var dropped = 0
        var closed = false

        var count: Int { storage.count - head }
    }

    private let capacity: Int
    private let state = Mutex(State())

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
            // Reclaim the consumed prefix once it has grown past one capacity's
            // worth. Amortized O(1): at most one compaction per `capacity`
            // pushes. The fully-drained case below is the common one; this
            // covers a consumer that keeps up only partially.
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
/// by the `@MainActor` run loop on each pass — the same cross-task hand-off
/// shape as `DatagramInbox`, and a separate object for the same reason the
/// inbox is not an actor: the loop needs a suspension-free read.
///
/// Without this, the detached receiver's `catch { continue }` swallowed a dead
/// socket forever: the loop kept ticking against an inbox that would never
/// fill again, and the viewer froze on its last frame with a live-looking UI.
final class ReceiveFailureFlag: Sendable {
    private let raised = Mutex(false)

    /// Called from the receive task, once, when the socket is declared dead.
    func raise() {
        raised.withLock { $0 = true }
    }

    /// Polled by the run loop.
    var isRaised: Bool {
        raised.withLock { $0 }
    }
}
