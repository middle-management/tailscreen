/// Where one outgoing invite to view stands (spec §13.3), as the sharer's
/// peer row shows it. Here rather than beside `SharerInviteCoordinator` so the
/// hub UI, which depends only on this module, can render it.
public enum InviteStatus: Sendable, Equatable {
    case waiting
    case accepted
    case declined
    /// Away, closed, or a build without invites — the sharer can't act on
    /// the difference.
    case noAnswer
}
