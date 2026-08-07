import Foundation
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
    public var controlListener: TailscreenControlListener? { listener }

    /// Matches the requester's own wait (`TailscreenRequestToShareClient`'s
    /// 120 s default). A row that outlives it is a button that does nothing.
    public static let requestTTLNs: UInt64 = 120 * 1_000_000_000

    private var inbox = ShareRequestInbox()
    private var listener: TailscreenControlListener?
    /// The node the listener was started against, so a profile switch (which
    /// brings a different node up) restarts it rather than leaving it bound to
    /// a node that is going away.
    private var listenerNode: TailscaleNode?

    /// Test seam: replaces the reply send, so the answer-on-the-arrival-
    /// connection contract is observable with no tsnet node behind the
    /// listener.
    var sendResponseForTesting: ((_ accepted: Bool, _ connectionID: UUID) -> Void)?

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
        guard let new = prepareListener(node: node) else { return }
        Task {
            do {
                try await new.start(node: node)
            } catch {
                onListenerError?(error)
            }
        }
    }

    /// The awaited variant, for a host that binds the listener as part of node
    /// bring-up and wants the failure to propagate (macOS).
    ///
    /// - Returns: whether a listener was newly started — false when one was
    ///   already bound to this node, so the caller can log the bind exactly
    ///   once.
    @discardableResult
    public func ensureListenerStarted(node: TailscaleNode) async throws -> Bool {
        guard let new = prepareListener(node: node) else { return false }
        try await new.start(node: node)
        return true
    }

    /// Stop and drop the listener — sign-out, or the node going away.
    public func stopListener() async {
        let previous = listener
        listener = nil
        listenerNode = nil
        await previous?.stop()
    }

    /// Create and wire the next listener, or nil when the current one is
    /// already bound to `node`. A previous listener bound to a different node
    /// is stopped on its way out.
    private func prepareListener(node: TailscaleNode) -> TailscreenControlListener? {
        if listener != nil, listenerNode === node { return nil }
        if let previous = listener { Task { await previous.stop() } }

        let new = TailscreenControlListener()
        new.onRequestToShare = { [weak self] hostname, connectionID, sourceAddr in
            // Fires on the listener's own thread; the inbox and its published
            // projection are main-actor state.
            Task { @MainActor [weak self] in
                self?.noteRequest(
                    from: hostname, sourceAddr: sourceAddr, connectionID: connectionID)
            }
        }
        configureListener?(new)
        listener = new
        listenerNode = node
        return new
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
            } else if let listener {
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
