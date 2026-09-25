import Foundation

/// The things a sharer needs to be interrupted about, and the rules for when
/// to interrupt them.
///
/// A sharer cannot poll: "Require approval for new viewers" defaults **on**,
/// so a sharer not watching the app would silently strand whoever tries to
/// connect. *What* to say and *when* is pure logic, living here rather than
/// in three host-specific notification backends — each supplies only
/// delivery (`UNUserNotificationCenter` on macOS, `org.freedesktop.Notifications`
/// on Linux, `AppNotificationManager` on Windows).
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
    /// A viewer sent a link to open. No buttons on purpose: a banner can
    /// truncate the URL, so the Open decision is made in-app, where the
    /// whole link is shown (TS-LNK-010).
    case linkOffered
}

extension SharerNoticeKind {
    /// Buttons this notice offers. Only the *asks* are actionable — a choice
    /// with no consequence trains people to ignore the ones that have one.
    public var actions: [NoticeAction] {
        switch self {
        case .viewerPending, .controlRequested, .requestToShare: [.approve, .deny]
        case .viewerJoined, .viewerLeft, .linkOffered: []
        }
    }

    /// Whether missing this notice strands someone **inside a session that is
    /// already running**. Hosts map this onto their platform's
    /// break-through-Do-Not-Disturb level (`UNNotificationInterruptionLevel.timeSensitive`
    /// on macOS, urgency `1`/`2` on freedesktop, `Urgent` on Windows).
    ///
    /// Higher bar than "is actionable": `requestToShare` is an ask but not
    /// urgent (arrives while idle, has a natural retry), while the other two
    /// arrive mid-share with someone unable to click anything. Spending the
    /// exemption on the least urgent kind loses it for the urgent ones too —
    /// users revoke Time Sensitive per *app*, not per notification.
    public var blocksSomeone: Bool {
        switch self {
        case .viewerPending, .controlRequested: true
        case .requestToShare, .viewerJoined, .viewerLeft, .linkOffered: false
        }
    }
}

/// What the user chose on a notice, normalized across platforms.
///
/// **The raw values are the action keys**, load-bearing: every platform's
/// notification button carries a user-facing label and a separate key that
/// comes back on press. Putting a *label* in the key slot works in English
/// and then a localized build's "Godkänn" misses the `"approve"` lookup with
/// no error — just a banner that swallows presses. Hosts localize the title
/// and pass `rawValue` verbatim as the key.
public enum NoticeAction: String, Codable, Sendable, CaseIterable {
    case approve
    case deny
    /// Closed without choosing. Distinct from `deny`: dismissing a banner
    /// must never be read as a decision about a peer. Never an offered
    /// button — hosts synthesize it from the "swiped away" signal.
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
    /// Also the **posted notification's identifier**: a re-post replaces the
    /// banner in place (every platform keys on this string), and it's the
    /// only thing surviving the round trip to the daemon and back — see
    /// `decodeID`.
    public var id: String { "\(kind.rawValue):\(identity)" }

    public init(kind: SharerNoticeKind, identity: String, label: String) {
        self.kind = kind
        self.identity = identity
        self.label = label
    }

    /// Recover the `(kind, identity)` an `id` was minted from — a pure
    /// parse, since a press arrives as an opaque string with no live state
    /// or notice object attached, possibly after the banner sat for an hour
    /// or an app restart.
    ///
    /// **Splits on the first colon, never the last.** `identity` is
    /// routinely full of colons (`ip:port`, IPv6), while no `rawValue`
    /// contains one. A last-colon split works for IPv4 only and would
    /// silently reroute between "let this person watch" and "let this
    /// person control my machine".
    ///
    /// Returns nil rather than guessing on anything it did not mint — a
    /// wrong guess acts on the wrong peer, strictly worse than a dead button.
    public static func decodeID(_ id: String) -> (kind: SharerNoticeKind, identity: String)? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        guard let kind = SharerNoticeKind(rawValue: String(id[id.startIndex..<separator])) else {
            return nil
        }
        let identity = String(id[id.index(after: separator)...])
        guard !identity.isEmpty else { return nil }
        return (kind, identity)
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
    /// Which of `candidates` should fire a notification, given who has
    /// already been notified — and the notified-set to carry into the next
    /// call.
    ///
    /// **Forget-on-leave.** An identity absent from `candidates` is pruned,
    /// so a peer that genuinely asks again is announced again, while a
    /// snapshot re-emitted for an unrelated reason announces nothing (hosts
    /// deliver whole-list snapshots, making set-intersection the right shape).
    ///
    /// **`identity` must be stable across reconnects at the level you want
    /// deduped** — keying per-connection is a spam vector (a peer that
    /// drops and redials mints a fresh id each time). The choice of key
    /// belongs to the caller, hence the opaque string.
    ///
    /// Order is preserved.
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

    /// Whether a notice may play a sound. Rule: not while capturing. A
    /// sharer capturing system audio captures the whole mix, and a
    /// notification ding is played by the daemon (not our process), so it's
    /// somebody else's audio that goes out on the wire with no way for the
    /// sharer to know viewers heard it too. Gated on the whole share, not
    /// "is system audio on", since that flag can flip between the decision
    /// and the sound.
    ///
    /// Only ever changes anything for `requestToShare` — the other kinds
    /// exist only *during* a share and are always silent under this
    /// rule.
    public static func playsSound(isCapturing: Bool) -> Bool {
        !isCapturing
    }

    /// Which already-notified identities are no longer in `candidates`, and
    /// whose notifications should therefore be taken back off the screen.
    /// Getting this wrong is invisible: a stale "waiting to be let in"
    /// banner with a dead Accept button (or, on an IP-keyed host, one that
    /// lands on whoever connects next).
    ///
    /// Call it BEFORE `noticesToPost` in the same pass, or with the same
    /// `alreadyNotified` — afterwards the set is already pruned and this
    /// returns nothing.
    public static func noticesToWithdraw(
        candidates: [NoticeCandidate], alreadyNotified: Set<String>
    ) -> Set<String> {
        alreadyNotified.subtracting(candidates.map(\.identity))
    }

    /// Whether a snapshot carrying `generation` should be dropped because a
    /// newer one was already applied. The server stamps
    /// `onControlGrantChanged` with a monotonic generation because every
    /// GUI host hops that callback to its UI thread, and a hop can reorder
    /// — applying a stale `nil` last would clear a grant that's actually
    /// live (macOS: unregistering the panic hotkey mid-control).
    ///
    /// Equal generations are **not** stale: racing notifies can legitimately
    /// observe the same pair, and re-applying is idempotent.
    public static func isStale(generation: UInt64, lastApplied: UInt64) -> Bool {
        generation < lastApplied
    }
}
