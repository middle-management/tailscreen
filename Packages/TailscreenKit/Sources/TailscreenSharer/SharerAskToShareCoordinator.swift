import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

/// The sharer's side of "somebody wants me to share", shared by all three
/// hosts (previously duplicated per host). Three load-bearing rules:
///
///   * **The listener outlives the share, idempotent per node.** Owns one
///     long-lived listener per node (`ensureListener`), passed into
///     `server.start(controlListener:)` so the share doesn't bind a second
///     one on port 7447.
///   * **The answer rides the connection the ask arrived on** — never a
///     dial-back, which would answer whoever now holds the claimed address.
///   * **Accept pre-approves the asker before the share starts** — its HELLO
///     can arrive the moment the share is up, and must not hit its own
///     approval gate a second time.
///
/// `ShareRequestInbox` handles coalescing/cap/expiry; this type adds the
/// sequencing and listener lifecycle. `@MainActor` since every host drives it
/// from its UI model.
@MainActor
public final class SharerAskToShareCoordinator {

    // MARK: Host closures

    /// Fired with the full inbox on every change (arrival, answer, expiry,
    /// clear) so the host's rows never drift from the connections behind them.
    public var onRequestsChanged: (([PendingShareRequest]) -> Void)?
    /// Every raw arrival, before the inbox decides anything.
    public var onRequestReceived: ((_ hostname: String) -> Void)?
    /// Accept's first half: waive the approval gate for the invited asker.
    /// Called BEFORE `onStartShare`.
    public var onPreApproveViewer: ((_ sourceKey: String) -> Void)?
    /// Accept's second half: start a share the way the host's own Share
    /// button would.
    public var onStartShare: (() -> Void)?
    /// The fire-and-forget `ensureListener` could not start its listener —
    /// this machine simply never hears an ask, indistinguishable from nobody
    /// being home.
    public var onListenerError: ((Error) -> Void)?
    /// Attach extra handlers to each newly created listener, before it starts.
    public var configureListener: ((TailscreenControlListener) -> Void)?

    // MARK: State

    /// Peers asking this machine to share, coalesced and bounded by the
    /// portable `ShareRequestInbox`.
    public private(set) var requests: [PendingShareRequest] = []

    /// The app's long-lived control listener, for `server.start(controlListener:)`
    /// — so the share doesn't create a second one competing for port 7447.
    ///
    /// Deliberately hands out a still-**starting** listener as readily as a
    /// running one: `server.start` binds its own when handed nil, which
    /// during the bring-up window is exactly the contention this type exists
    /// to prevent.
    public var controlListener: TailscreenControlListener? {
        listenerState.withLock { $0.phase.listener }
    }

    /// Matches the requester's own wait (`TailscreenRequestToShareClient`'s
    /// 120 s default). A row that outlives it is a button that does nothing.
    public static let requestTTLNs: UInt64 = 120 * 1_000_000_000

    private var inbox = ShareRequestInbox()

    /// Where the long-lived listener is in its life.
    ///
    /// Three phases, not a `(listener, node)` pair — that pair couldn't say
    /// "created, not bound yet", so a bring-up racing a supersede/stop in
    /// that window left an untracked listener still binding port 7447, or (on
    /// a throw) a stale "already bound" entry that silenced the machine to
    /// every later ask.
    private enum Phase {
        case idle
        /// Created and being started against `node`. Already handed out by
        /// `controlListener` — see the note there.
        case starting(TailscreenControlListener, node: TailscaleNode?)
        case running(TailscreenControlListener, node: TailscaleNode?)

        var listener: TailscreenControlListener? {
            switch self {
            case .idle: return nil
            case .starting(let listener, _), .running(let listener, _): return listener
            }
        }

        var node: TailscaleNode? {
            switch self {
            case .idle: return nil
            case .starting(_, let node), .running(_, let node): return node
            }
        }
    }

    private struct ListenerState {
        var phase: Phase = .idle
        /// Stamped on every bring-up, bumped on every teardown, so an
        /// in-flight start can tell if it's been superseded — the node
        /// reference alone can't, since a supersede back to the same node is
        /// legitimate.
        var generation: UInt64 = 0
    }

    /// The listener's whole lifecycle behind one lock: every transition is a
    /// single take-and-clear, since `@MainActor` alone doesn't prevent a
    /// read/write split across an `await`.
    private let listenerState = Guarded(ListenerState())

    /// A bring-up this coordinator has committed to. Handed back by
    /// `beginBringUp` so the caller can start the listener and report the
    /// outcome under the generation it was stamped with.
    private struct PendingBringUp {
        let listener: TailscreenControlListener
        let node: TailscaleNode?
        let generation: UInt64
    }

    /// What one `ensureListener` decides under the lock: the bring-up to
    /// start (nil if already bound/starting), and the superseded listener to
    /// stop outside the lock.
    private typealias BringUpDecision = (PendingBringUp?, TailscreenControlListener?)

    /// Test seam: replaces the reply send, so the answer-on-the-arrival-
    /// connection contract is observable with no tsnet node behind the
    /// listener.
    var sendResponseForTesting: ((_ accepted: Bool, _ connectionID: UUID) -> Void)?

    /// Test seam: replaces `TailscreenControlListener.stop()` on the teardown
    /// and supersede paths, so *when* a superseded listener is stopped is
    /// observable with no tsnet node.
    var stopListenerForTesting: ((TailscreenControlListener) async -> Void)?

    public init() {}

    // MARK: Listener lifecycle

    /// Bring up (or re-point) the idle control listener, without waiting.
    /// Idempotent per node, safe to call on every node change. A listener
    /// already bound to the same node is left alone; start failures go to
    /// `onListenerError`.
    public func ensureListener(node: TailscaleNode) {
        bringUp(node: node) { listener in try await listener.start(node: node) }
    }

    /// The awaited variant, for a host that binds the listener as part of node
    /// bring-up and wants the failure to propagate (macOS).
    ///
    /// - Returns: whether a listener was newly started — false when one was
    ///   already bound to (or being bound to) this node, so the caller can log
    ///   the bind exactly once.
    @discardableResult
    public func ensureListenerStarted(node: TailscaleNode) async throws -> Bool {
        try await bringUpAwaiting(node: node) { listener in try await listener.start(node: node) }
    }

    /// Stop and drop the listener — sign-out, or the node going away.
    ///
    /// Take-and-clear plus a generation bump in one locked step. The bump
    /// reaches a bring-up still in flight: `stop()` on a listener whose
    /// `start()` hasn't returned is a no-op, so tearing it down relies on
    /// `finishBringUp` seeing it was superseded.
    public func stopListener() async {
        let previous = listenerState.withLock { state -> TailscreenControlListener? in
            let live: TailscreenControlListener?
            if case .running(let listener, _) = state.phase { live = listener } else { live = nil }
            state.generation &+= 1
            state.phase = .idle
            return live
        }
        if let previous { await stop(previous) }
    }

    /// Fire-and-forget bring-up: claim the state, then start off the actor.
    /// `start` is a parameter (not a direct call) so tests can drive this
    /// without standing up a real tsnet node.
    private func bringUp(
        node: TailscaleNode?,
        start: @escaping (TailscreenControlListener) async throws -> Void
    ) {
        guard let pending = beginBringUp(node: node) else { return }
        Task {
            do {
                try await start(pending.listener)
                finishBringUp(pending, failed: false)
            } catch {
                finishBringUp(pending, failed: true)
                onListenerError?(error)
            }
        }
    }

    /// The awaited shape of `bringUp`, whose failure the caller propagates
    /// rather than routing to `onListenerError`.
    private func bringUpAwaiting(
        node: TailscaleNode?,
        start: (TailscreenControlListener) async throws -> Void
    ) async throws -> Bool {
        guard let pending = beginBringUp(node: node) else { return false }
        do {
            try await start(pending.listener)
        } catch {
            finishBringUp(pending, failed: true)
            throw error
        }
        finishBringUp(pending, failed: false)
        return true
    }

    /// Test seam onto `bringUp` with no tsnet node: `node` is nil, so every
    /// call supersedes the last.
    func ensureListenerForTesting(
        start: @escaping (TailscreenControlListener) async throws -> Void
    ) {
        bringUp(node: nil, start: start)
    }

    /// Claim the bring-up, or nil when one is already in flight or bound for
    /// `node`.
    private func beginBringUp(node: TailscaleNode?) -> PendingBringUp? {
        // Built before the lock: `configureListener` is the host's code and
        // must not run under it.
        let fresh = TailscreenControlListener()
        fresh.onRequestToShare = { [weak self] hostname, connectionID, sourceAddr in
            // Fires on the listener's own thread; inbox state is main-actor.
            Task { @MainActor [weak self] in
                self?.noteRequest(
                    from: hostname, sourceAddr: sourceAddr, connectionID: connectionID)
            }
        }
        configureListener?(fresh)

        let (pending, supersededRunning) = listenerState.withLock { state -> BringUpDecision in
            // A bring-up already in flight for this node counts as bound.
            if let bound = state.phase.node, bound === node { return (nil, nil) }
            var running: TailscreenControlListener?
            if case .running(let live, _) = state.phase { running = live }
            // A `.starting` listener is NOT collected here — the generation
            // bump tears it down from its own completion (see stopListener).
            state.generation &+= 1
            state.phase = .starting(fresh, node: node)
            return (
                PendingBringUp(listener: fresh, node: node, generation: state.generation),
                running
            )
        }
        guard let pending else { return nil }
        if let supersededRunning { Task { await self.stop(supersededRunning) } }
        return pending
    }

    /// Record how a bring-up ended, or tear it down if it was superseded while
    /// it was still starting.
    private func finishBringUp(_ pending: PendingBringUp, failed: Bool) {
        let superseded = listenerState.withLock { state -> Bool in
            guard state.generation == pending.generation else { return true }
            // A failed start bound nothing, so go back to idle rather than
            // parking a dead listener that would short-circuit every later
            // `ensure` on "already bound".
            state.phase =
                failed ? .idle : .running(pending.listener, node: pending.node)
            return false
        }
        guard superseded else { return }
        Task { await self.stop(pending.listener) }
    }

    private func stop(_ listener: TailscreenControlListener) async {
        if let stopListenerForTesting {
            await stopListenerForTesting(listener)
        } else {
            await listener.stop()
        }
    }

    /// Test seam: the bring-up phase as a word.
    var listenerPhaseForTesting: String {
        listenerState.withLock { state in
            switch state.phase {
            case .idle: return "idle"
            case .starting: return "starting"
            case .running: return "running"
            }
        }
    }

    // MARK: Inbox

    /// Record an incoming ask. Public so a host with its own transport can
    /// route into the same inbox; the listener `ensureListener` builds calls
    /// it for everyone else. `nowNs` is injectable for the expiry tests.
    public func noteRequest(
        from hostname: String, sourceAddr: String?, connectionID: UUID?,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        onRequestReceived?(hostname)
        // Expire first, so a two-minute-old row that the asker has already
        // given up on cannot occupy a slot against a live one.
        _ = inbox.pruneExpired(nowNs: nowNs, ttlNs: Self.requestTTLNs)
        guard
            inbox.record(
                fromHostname: hostname, sourceAddr: sourceAddr,
                connectionID: connectionID, nowNs: nowNs)
        else { return }
        publish()
    }

    /// Answer an ask: reply on its own connection, and on accept pre-approve
    /// the asker and hand off to the host's share flow.
    public func answer(id: UUID, accept: Bool) {
        guard let request = inbox.remove(id: id) else { return }
        publish()

        if let connectionID = request.connectionID {
            if let sendResponseForTesting {
                sendResponseForTesting(accept, connectionID)
            } else if let listener = controlListener {
                Task {
                    // Best effort: the asker may have given up and closed.
                    // Sending into a dead connection is not an error worth
                    // surfacing — their side already settled on `.noAnswer`.
                    await listener.send(.shareResponse(accepted: accept), to: connectionID)
                }
            }
        }
        guard accept else { return }

        // Pre-approve BEFORE starting — see the type comment's third rule.
        onPreApproveViewer?(request.sourceKey)
        onStartShare?()
    }

    /// Forget every parked ask — the share started by another route, or the
    /// node went away. Askers get no reply and settle on `.noAnswer`, exactly
    /// as if nobody had been home.
    public func clearRequests() {
        guard !inbox.requests.isEmpty else { return }
        inbox.removeAll()
        publish()
    }

    private func publish() {
        requests = inbox.requests
        onRequestsChanged?(inbox.requests)
    }
}
