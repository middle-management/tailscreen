import Foundation
import TailscreenProtocol
import TailscreenTransport

/// The sharer's side of "come watch my share" (spec §13.3), shared by all
/// three hosts: send an invite per peer, show its outcome on that peer's row,
/// and pre-approve the peer that accepts.
///
/// Two silent failure modes this type exists to prevent:
///   * **A late accept leaking into the next share.** Invites are scoped to
///     one share; `endShare()` bumps a generation so an answer arriving after
///     Stop Sharing pre-approves nothing (TS-MET-026).
///   * **Pre-approval without an accept.** Only `.accepted` reaches
///     `onPreApproveViewer`; a decline or silence never does.
@MainActor
public final class SharerInviteCoordinator {

    public enum Status: Sendable, Equatable {
        case waiting
        case accepted
        case declined
        case noAnswer
    }

    /// Fired on every status change, keyed by the invited peer's IP.
    public var onStatusesChanged: (([String: Status]) -> Void)?
    /// The peer accepted: let its HELLO past the approval gate. Fires before
    /// the status publishes, so a host reacting to `.accepted` sees it done.
    public var onPreApproveViewer: ((_ ip: String) -> Void)?

    public private(set) var statuses: [String: Status] = [:]

    /// The wire call, injected so the sequencing is testable with no node.
    /// Hosts pass a closure over `TailscreenInviteToViewClient.invite`.
    public typealias Send = @Sendable (_ ip: String, _ fromHostname: String) async ->
        ShareRequestOutcome

    private let send: Send
    private var generation: UInt64 = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(send: @escaping Send) {
        self.send = send
    }

    /// Invite `ip`. Ignored while an invite to it is already waiting, so a
    /// double click can't stack two prompts on the invitee.
    public func invite(ip: String, fromHostname: String) {
        guard statuses[ip] != .waiting else { return }
        set(ip, .waiting)
        let stamp = generation
        let send = self.send
        tasks[ip] = Task { [weak self] in
            let outcome = await send(ip, fromHostname)
            self?.finish(ip: ip, outcome: outcome, generation: stamp)
        }
    }

    /// The share stopped: forget every invite and ignore answers still in
    /// flight. Their connections close, which the invitee reads as the
    /// sharer giving up.
    public func endShare() {
        generation &+= 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        guard !statuses.isEmpty else { return }
        statuses.removeAll()
        onStatusesChanged?(statuses)
    }

    private func finish(ip: String, outcome: ShareRequestOutcome, generation stamp: UInt64) {
        guard stamp == generation else { return }
        tasks[ip] = nil
        switch outcome {
        case .accepted:
            onPreApproveViewer?(ip)
            set(ip, .accepted)
        case .declined:
            set(ip, .declined)
        case .noAnswer:
            set(ip, .noAnswer)
        }
    }

    private func set(_ ip: String, _ status: Status) {
        statuses[ip] = status
        onStatusesChanged?(statuses)
    }
}
