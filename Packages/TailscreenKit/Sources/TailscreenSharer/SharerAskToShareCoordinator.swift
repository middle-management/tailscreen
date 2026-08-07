import Foundation
import Synchronization
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

/// The sharer's side of "somebody wants me to share", written once.
///
/// Before this existed the flow was written three times — the GTK engine, the
/// Windows app and macOS `AppState` — line-for-line equivalent and each
/// carrying the same three load-bearing rules, any of which a fourth copy
/// would eventually drop:
///
///   * **The listener outlives the share, idempotent per node.**
///     `TailscaleScreenShareServer` creates a control listener when the caller
///     supplies none, but only for the share's lifetime — and an ask to share
///     arrives exactly when this machine is NOT sharing. So the coordinator
///     owns one long-lived listener per node (`ensureListener`), and the host
///     passes `controlListener` into `server.start`, which is also what stops
///     a second listener contending for port 7447. Re-pointing on a node
///     change (a profile switch) is the same call.
///   * **The answer rides the connection the ask arrived on.** Never a
///     dial-back, which would answer whoever currently holds the requester's
///     claimed address rather than the peer that actually asked.
///   * **Accept pre-approves the asker before the share starts.** The
///     invitee's HELLO can arrive the moment the share is up, and a peer this
///     machine just invited must not then be parked at its own approval gate —
///     the same person prompted twice, seconds apart. Accept necessarily
///     happens before a server exists, so the host's `onPreApproveViewer` is
///     expected to hold the IP and replay it in the same window that sets the
///     gate and the policies (all three hosts already do).
///
/// The inbox itself — coalescing on the requester's source IP, the cap, the
/// expiry — is `ShareRequestInbox`; this type adds the sequencing around it
/// and the listener's lifecycle. `@MainActor` because every host drives it
/// from its UI model and publishes `requests` straight into its chrome.
@MainActor
public final class SharerAskToShareCoordinator {

    // MARK: Host closures

    /// The pending-prompt surface: fired with the full inbox on every change —
    /// arrival, answer, expiry-on-arrival, clear — so the host's rows and its
    /// notification reconcile can never drift from the connections behind
    /// them.
    public var onRequestsChanged: (([PendingShareRequest]) -> Void)?
    /// Every raw arrival, before the inbox decides anything — the hook for a
    /// host's log line.
    public var onRequestReceived: ((_ hostname: String) -> Void)?
    /// Accept's first half: waive the approval gate for the invited asker.
    /// Called with the requester's source key BEFORE `onStartShare`, so the
    /// invitee is known to the gate by the time a share exists to admit them.
    public var onPreApproveViewer: ((_ sourceKey: String) -> Void)?
    /// Accept's second half: start a share the way the host's own Share
    /// button would — the picker, the backend choice, the consent dialog are
    /// all the host's.
    public var onStartShare: (() -> Void)?
    /// The fire-and-forget `ensureListener` could not start its listener.
    /// Worth surfacing rather than swallowing: sharing still works and this
    /// machine simply never hears an ask, which from the other end is
    /// indistinguishable from nobody being home.
    public var onListenerError: ((Error) -> Void)?
    /// Attach extra handlers to each newly created listener, before it starts.
    /// The macOS host answers `.metadataRequest` on the same listener; a host
    /// with nothing extra leaves this nil.
    public var configureListener: ((TailscreenControlListener) -> Void)?

    // MARK: State

    /// Peers asking this machine to share, coalesced and bounded by the
    /// portable `ShareRequestInbox`.
    public private(set) var requests: [PendingShareRequest] = []

    /// The app's long-lived control listener, for `server.start(controlListener:)`
    /// — so the share does not create a second one competing for port 7447,
    /// and so `onRequestToShare` keeps pointing here rather than being rebound
    /// to the share's own.
    ///
    /// Hands out a listener that is still **starting** as readily as a running
    /// one, and that is deliberate: `server.start(controlListener:)` never
    /// starts what it is given, but it *does* create and bind its own when
    /// handed nil — which on port 7447 is the exact contention this whole type
    /// exists to prevent. A listener mid-bring-up is the right answer; nil
    /// during the bring-up window is the wrong one.
    public var controlListener: TailscreenControlListener? {
        listenerState.withLock { $0.phase.listener }
    }

    /// Matches the requester's own wait (`TailscreenRequestToShareClient`'s
    /// 120 s default). A row that outlives it is a button that does nothing.
    public static let requestTTLNs: UInt64 = 120 * 1_000_000_000

    private var inbox = ShareRequestInbox()

    /// Where the long-lived listener is in its life.
    ///
    /// Three phases rather than the `(listener, listenerNode)` pair this used
    /// to be, because that pair had no way to say **"created, not bound
    /// yet"** — and every race lived in exactly that gap. `listener` was
    /// assigned before `start(node:)` ran, so a bring-up for a different node
    /// arriving in the window stopped a listener that had not started (a
    /// no-op, since `stop()` only clears `isRunning` and `start()` sets it
    /// again), and the abandoned listener went on to bind port 7447 with
    /// nothing tracking it — two listeners contending, one of them
    /// unreachable. `stopListener()` lost the same race for the same reason.
    /// And a `start` that *threw* left the pair populated, so every later
    /// `ensure` short-circuited on "already bound to this node" and this
    /// machine never heard an ask again.
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
        /// Stamped on every bring-up and bumped by every teardown, so a start
        /// that is still in flight can tell whether it is still the current
        /// one when it finally returns. The node reference alone cannot
        /// answer that: a supersede back to the *same* node is legitimate.
        var generation: UInt64 = 0
    }

    /// The listener's whole lifecycle behind one lock, in the style of
    /// `TailscaleScreenShareServer`'s `Mutex<Lifecycle>`: every transition is
    /// a single take-and-clear, so a supersede can never be split into a read
    /// and a write with an `await` in between (which is what a `@MainActor`
    /// alone does not stop — the actor releases across every suspension).
    private let listenerState = Mutex(ListenerState())

    /// A bring-up this coordinator has committed to. Handed back by
    /// `beginBringUp` so the caller can start the listener and report the
    /// outcome under the generation it was stamped with.
    private struct PendingBringUp {
        let listener: TailscreenControlListener
        let node: TailscaleNode?
        let generation: UInt64
    }

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
    ///
    /// Idempotent per node and safe to call on every node change — which is
    /// how the swift-cross-ui hosts call it, because there is no single
    /// observable "the node is ready" moment there. A listener already bound
    /// to the same node is left alone. Start failures go to
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
    /// Take-and-clear plus a generation bump, in one locked step. The bump is
    /// what reaches a bring-up that is still in flight: `stop()` on a listener
    /// whose `start()` has not returned does nothing at all (it clears
    /// `isRunning`, which `start()` then sets on its way to binding), so the
    /// only way to tear one of those down is to let its own completion see
    /// that it was superseded — which `finishBringUp` does.
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
    ///
    /// `start` is a parameter rather than a call to
    /// `TailscreenControlListener.start(node:)` so the package tests can drive
    /// this state machine — a `TailscaleNode` cannot be constructed without
    /// standing a real tsnet node up.
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

    /// Test seam onto `bringUp` with no tsnet node: `node` is nil, which never
    /// matches a later bring-up's node, so every call supersedes — the shape
    /// the leak cases need.
    func ensureListenerForTesting(
        start: @escaping (TailscreenControlListener) async throws -> Void
    ) {
        bringUp(node: nil, start: start)
    }

    /// Claim the bring-up, or nil when one is already in flight or bound for
    /// `node`.
    private func beginBringUp(node: TailscaleNode?) -> PendingBringUp? {
        // Built before the lock: construction is cheap, but `configureListener`
        // is the host's code and must not run under it.
        let fresh = TailscreenControlListener()
        fresh.onRequestToShare = { [weak self] hostname, connectionID, sourceAddr in
            // Fires on the listener's own thread; the inbox and its published
            // projection are main-actor state.
            Task { @MainActor [weak self] in
                self?.noteRequest(
                    from: hostname, sourceAddr: sourceAddr, connectionID: connectionID)
            }
        }
        configureListener?(fresh)

        let (pending, supersededRunning) = listenerState.withLock {
            state -> (PendingBringUp?, TailscreenControlListener?) in
            // A bring-up already in flight for this node counts as bound: two
            // ensures for one node must not produce two listeners on 7447.
            if let bound = state.phase.node, bound === node { return (nil, nil) }
            var running: TailscreenControlListener?
            if case .running(let live, _) = state.phase { running = live }
            // A `.starting` listener is deliberately NOT collected here — see
            // `stopListener`. The generation bump is what tears it down, from
            // its own completion, once it has actually bound something.
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
            // A start that threw bound nothing, so go back to idle rather than
            // parking a dead listener in the state: leaving it there is what
            // made every later `ensure` short-circuit on "already bound" and
            // this machine never hear an ask again, with no way back short of
            // a restart.
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
