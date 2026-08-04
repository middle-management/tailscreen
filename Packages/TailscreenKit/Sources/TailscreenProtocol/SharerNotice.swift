import Foundation

/// The things a sharer needs to be interrupted about, and the rules for when
/// to interrupt them.
///
/// A sharer cannot poll. "Require approval for new viewers" defaults **on**,
/// so a sharer who is not watching the app silently strands whoever tries to
/// connect — there is nothing on screen to notice and no way to find out. A
/// notification is the only surface that reaches someone whose attention is on
/// the thing they are sharing.
///
/// *What* to say and *when* is pure logic, so it lives here rather than in
/// three host-specific notification backends. Each host supplies only delivery:
/// `UNUserNotificationCenter` on macOS, `org.freedesktop.Notifications` on
/// Linux, `AppNotificationManager` on Windows.
public enum SharerNoticeKind: String, Codable, Sendable, CaseIterable {
    /// A viewer is parked at the approval gate, waiting on Accept/Deny.
    case viewerPending
    /// An admitted viewer is asking for remote control.
    case controlRequested
    /// A peer is asking *this* machine to start sharing.
    case requestToShare
    /// A viewer's video started flowing. Informational.
    case viewerJoined
    /// A viewer's session ended — they disconnected, or were dropped.
    /// Informational.
    case viewerLeft
}

extension SharerNoticeKind {
    /// Buttons this notice offers.
    ///
    /// Only the *asks* are actionable. The two reports describe something that
    /// already happened, and a notification offering a choice with no
    /// consequence trains people to ignore the ones that have one.
    public var actions: [NoticeAction] {
        switch self {
        case .viewerPending, .controlRequested, .requestToShare: [.approve, .deny]
        case .viewerJoined, .viewerLeft: []
        }
    }

    /// Whether missing this notice strands someone **inside a session that is
    /// already running**.
    ///
    /// Hosts map this onto their platform's break-through-Do-Not-Disturb level
    /// — `UNNotificationInterruptionLevel.timeSensitive` on macOS, urgency
    /// `1`/`2` on freedesktop, `Urgent` on Windows.
    ///
    /// The bar is deliberately higher than "is actionable". `requestToShare` is
    /// an ask and is *not* urgent: it arrives while this machine is idle,
    /// nobody is mid-flow, and an invitation has a natural retry — the peer
    /// asks again or messages you. The other two asks arrive while you are
    /// already sharing, with a person watching a "waiting for approval" placard
    /// or unable to click anything.
    ///
    /// Spending the exemption on the least urgent notice is also how you lose
    /// it for the urgent ones: the user revokes Time Sensitive per *app*, not
    /// per notification, so one over-eager kind disarms the whole set.
    public var blocksSomeone: Bool {
        switch self {
        case .viewerPending, .controlRequested: true
        case .requestToShare, .viewerJoined, .viewerLeft: false
        }
    }
}

/// What the user chose on a notice, normalized across platforms.
public enum NoticeAction: String, Codable, Sendable, CaseIterable {
    case approve
    case deny
    /// Closed without choosing. Distinct from `deny` on purpose: dismissing a
    /// banner must never be read as a decision about a peer.
    case dismiss
}

/// One thing worth telling the sharer about.
public struct SharerNotice: Equatable, Sendable, Identifiable {
    public let kind: SharerNoticeKind
    /// The dedupe key — see `SharerNoticeDecision.noticesToPost` for what
    /// makes a good one.
    public let identity: String
    /// Human-facing name for the peer: hostname, else its Tailscale IP.
    public let label: String

    /// Unique across kinds, so one host-side notified-set can serve all three
    /// without a peer's pending notice suppressing its later control request.
    public var id: String { "\(kind.rawValue):\(identity)" }

    /// The inverse of `id`.
    ///
    /// Needed by a host whose notification platform hands back **one opaque
    /// string** and nothing else — Windows, where a button press arrives as
    /// the activation argument the toast was posted with, long after whatever
    /// table might have remembered what it meant. Rather than keep that table,
    /// the id carries both halves and this reads them out.
    ///
    /// Split on the FIRST colon, not the last and not all of them: kinds never
    /// contain one, and identities routinely do — `"100.64.0.1:51820"` for a
    /// viewer at the gate. Splitting anywhere else silently reroutes an
    /// answer, and the two things it could reroute between are "let this
    /// person watch" and "let this person control my machine".
    ///
    /// Nil for anything that is not one of ours, since the platform delivers
    /// activation arguments from whatever posted them.
    public static func decodeID(_ id: String) -> (kind: SharerNoticeKind, identity: String)? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        guard let kind = SharerNoticeKind(rawValue: String(id[id.startIndex..<separator])) else {
            return nil
        }
        let identity = String(id[id.index(after: separator)...])
        guard !identity.isEmpty else { return nil }
        return (kind, identity)
    }

    public init(kind: SharerNoticeKind, identity: String, label: String) {
        self.kind = kind
        self.identity = identity
        self.label = label
    }
}

/// A row a host is considering notifying about, reduced to the two fields the
/// decision needs. Hosts project their own types (`PendingViewerInfo`,
/// `ControlRequestInfo`, …) into this.
public struct NoticeCandidate: Equatable, Sendable {
    public let identity: String
    public let label: String

    public init(identity: String, label: String) {
        self.identity = identity
        self.label = label
    }
}

/// Pure decisions behind sharer notifications.
public enum SharerNoticeDecision {
    /// Which of `candidates` should fire a notification, given who has already
    /// been notified — and the notified-set to carry into the next call.
    ///
    /// **Forget-on-leave.** An identity absent from `candidates` is pruned, so
    /// a peer that gives up and genuinely asks again is announced again, while
    /// a snapshot re-emitted for an unrelated reason (a hostname finally
    /// resolving, another row changing) announces nothing. Every host delivers
    /// these as whole-list snapshots rather than deltas, which is what makes a
    /// set-intersection the right shape.
    ///
    /// **`identity` must be stable across reconnects at the level you want
    /// deduped.** Keying on something per-connection is a spam vector: a peer
    /// that drops and redials mints a fresh connection id every time and would
    /// notify on every one. macOS learned this on the control path and keys by
    /// viewer **IP**; its viewer-roster path keys by `ip:port` deliberately, so
    /// a genuine rejoin does ping again. Both are correct — the choice belongs
    /// to the caller, which is why this takes an opaque string.
    ///
    /// Order is preserved: hosts post in the order the platform received them.
    public static func noticesToPost(
        kind: SharerNoticeKind,
        candidates: [NoticeCandidate],
        alreadyNotified: Set<String>
    ) -> (post: [SharerNotice], notified: Set<String>) {
        var notified = alreadyNotified.intersection(candidates.map(\.identity))
        var post: [SharerNotice] = []
        for candidate in candidates where !notified.contains(candidate.identity) {
            notified.insert(candidate.identity)
            post.append(
                SharerNotice(kind: kind, identity: candidate.identity, label: candidate.label))
        }
        return (post, notified)
    }

    /// Which already-notified identities are no longer in `candidates`, and
    /// whose notifications should therefore be taken back off the screen.
    ///
    /// The exact set `noticesToPost` discards when it intersects, named and
    /// returned so hosts do not each re-derive it — and so it is tested, which
    /// matters because getting it wrong is invisible. A banner reading
    /// "someone is waiting to be let in", with an Accept button, is actively
    /// WRONG once they have been let in from the app window: pressing it does
    /// nothing, and on a host that keys by IP rather than `ip:port` it could
    /// land on whoever connects next.
    ///
    /// Call it BEFORE `noticesToPost` in the same pass, or with the same
    /// `alreadyNotified` — afterwards the set has already been pruned and this
    /// returns nothing.
    public static func noticesToWithdraw(
        candidates: [NoticeCandidate], alreadyNotified: Set<String>
    ) -> Set<String> {
        alreadyNotified.subtracting(candidates.map(\.identity))
    }

    /// Whether a snapshot carrying `generation` should be dropped because a
    /// newer one was already applied.
    ///
    /// The sharer server stamps `onControlGrantChanged` with a monotonic
    /// generation because every GUI host hops that callback to its UI thread,
    /// and a hop can reorder. Applying a stale `nil` snapshot last would clear
    /// a grant that is actually live — on macOS that unregisters the ⌃⌥. panic
    /// hotkey while a viewer is still controlling the machine.
    ///
    /// Equal generations are **not** stale: two racing notifies can legitimately
    /// observe the same pair, and re-applying it is idempotent.
    public static func isStale(generation: UInt64, lastApplied: UInt64) -> Bool {
        generation < lastApplied
    }
}
