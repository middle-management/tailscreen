import Foundation
import TailscreenProtocol
import TailscreenTransport

/// The invitee's side of "come watch my share" (spec §13.3), shared by all
/// three hosts. Owned by `SharerAskToShareCoordinator`, whose long-lived
/// listener is what hears the invite whether or not this machine shares.
///
/// Rules, each with a silent failure mode:
///   * **Join only on a click** (TS-MET-023) — nothing here opens a viewer;
///     `answer(accept: true)` is the only path to `onJoin`.
///   * **Join the invite's source address** (TS-MET-022), never anything from
///     the payload. An invite with no source address is dropped: there is
///     nothing safe to join.
///   * **Answer on the arrival connection** (TS-MET-021), never a dial-back.
///
/// Coalescing, cap and expiry are `ShareRequestInbox`'s — an invite has the
/// same shape as an ask (hostname, source key, connection, TTL).
@MainActor
public final class IncomingInviteCoordinator {

    /// Fired with the full inbox on every change, so rows never drift from
    /// the connections behind them.
    public var onInvitesChanged: (([PendingShareRequest]) -> Void)?
    /// Every accepted-into-the-inbox arrival — for an OS notification.
    public var onInviteReceived: ((_ invite: PendingShareRequest) -> Void)?
    /// The user clicked Join: connect a viewer to `ip` (the invite's source
    /// address). `fromHostname` is for the window title only.
    public var onJoin: ((_ ip: String, _ fromHostname: String) -> Void)?

    public private(set) var invites: [PendingShareRequest] = []

    /// The sharer's own wait (`TailscreenInviteToViewClient`'s default). A
    /// row past it answers a connection that has already given up.
    public static let inviteTTLNs: UInt64 = 120 * 1_000_000_000

    private var inbox = ShareRequestInbox()

    /// Where replies go. Set by the owning `SharerAskToShareCoordinator`.
    var listenerProvider: () -> TailscreenControlListener? = { nil }

    /// Test seam: replaces the reply send.
    var sendResponseForTesting: ((_ accepted: Bool, _ connectionID: UUID) -> Void)?

    public init() {}

    /// Record an incoming invite. `nowNs` is injectable for the expiry tests.
    public func noteInvite(
        from hostname: String, sourceAddr: String?, connectionID: UUID?,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard let sourceAddr, !ShareRequestInbox.sourceKey(from: sourceAddr).isEmpty else { return }
        let pruned = inbox.pruneExpired(nowNs: nowNs, ttlNs: Self.inviteTTLNs)
        let isNew = !inbox.requests.contains {
            $0.sourceKey == ShareRequestInbox.sourceKey(from: sourceAddr)
        }
        guard
            inbox.record(
                fromHostname: hostname, sourceAddr: sourceAddr,
                connectionID: connectionID, nowNs: nowNs)
        else {
            if pruned { publish() }
            return
        }
        publish()
        // A retry from a sharer already listed refreshes the row but doesn't
        // notify again.
        if isNew, let invite = inbox.requests.last { onInviteReceived?(invite) }
    }

    /// Answer an invite on its own connection; on accept, hand the source
    /// address to the host's viewer.
    public func answer(id: UUID, accept: Bool) {
        guard let invite = inbox.remove(id: id) else { return }
        publish()

        if let connectionID = invite.connectionID {
            if let sendResponseForTesting {
                sendResponseForTesting(accept, connectionID)
            } else if let listener = listenerProvider() {
                // Best effort: a sharer that gave up already reads `.noAnswer`.
                Task { await listener.send(.shareResponse(accepted: accept), to: connectionID) }
            }
        }
        guard accept else { return }
        onJoin?(invite.sourceKey, invite.fromHostname)
    }

    /// Forget every parked invite — the listener went away. Sharers get no
    /// reply and settle on `.noAnswer`.
    public func clearInvites() {
        guard !inbox.requests.isEmpty else { return }
        inbox.removeAll()
        publish()
    }

    private func publish() {
        invites = inbox.requests
        onInvitesChanged?(inbox.requests)
    }
}
