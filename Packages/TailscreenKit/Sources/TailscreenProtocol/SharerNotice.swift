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
///
/// **The raw values are the action keys**, and that is load-bearing rather than
/// incidental. Every platform's notification button carries two strings — one
/// the user reads, one that comes back when it is pressed — and only the second
/// is ours. `UNNotificationAction(identifier:title:)`, freedesktop's
/// `actions` array of (key, label) pairs and `AppNotificationButton`'s
/// argument string are all the same shape.
///
/// Putting a *label* in the key slot is the failure this doc exists to prevent.
/// It works perfectly in English and then a localized build hands back "Godkänn"
/// where the router expects "approve", the lookup misses, and the button does
/// nothing at all — no error, no log line, just a banner that swallows presses.
/// So hosts localize the title and pass `rawValue` verbatim as the key, and
/// route a press back through `NoticeAction(rawValue:)` — which returns nil for
/// anything it did not mint, including a translated label.
public enum NoticeAction: String, Codable, Sendable, CaseIterable {
    case approve
    case deny
    /// Closed without choosing. Distinct from `deny` on purpose: dismissing a
    /// banner must never be read as a decision about a peer.
    ///
    /// Never an offered button (see `SharerNoticeKind.actions`) — hosts
    /// synthesize it from their platform's "user swiped it away" signal.
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
    ///
    /// Also the **posted notification's identifier**, which buys two things a
    /// random UUID did not. A re-post of the same notice replaces the banner
    /// in place instead of stacking a second one — every platform keys
    /// replacement on this string. And it is the only thing that survives the
    /// round trip out to the notification daemon and back, so it is how a
    /// button press finds the peer it was about: see `decodeID`.
    public var id: String { "\(kind.rawValue):\(identity)" }

    public init(kind: SharerNoticeKind, identity: String, label: String) {
        self.kind = kind
        self.identity = identity
        self.label = label
    }

    /// Recover the `(kind, identity)` an `id` was minted from.
    ///
    /// A press arrives from the notification daemon as two opaque strings —
    /// the notification's identifier and the action key — and nothing else.
    /// Neither the host's live state nor the notice object is attached, and
    /// the banner may have sat in a notification centre for an hour, so this
    /// has to be a pure parse of the identifier.
    ///
    /// **Splits on the first colon, never the last.** `identity` is routinely
    /// full of colons — the viewer roster keys by `ip:port`, and an IPv6
    /// literal is mostly colons — while no kind's `rawValue` contains one. A
    /// last-colon split works on IPv4 for exactly as long as nobody shares
    /// over IPv6.
    ///
    /// Returns nil rather than guessing on anything it did not mint: an
    /// unknown kind (an id from a newer build sitting in notification centre
    /// across an update), or an empty identity. A wrong guess here acts on the
    /// wrong peer, which is strictly worse than a button that does nothing.
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

    /// Whether a notice may play a sound.
    ///
    /// The rule is "not while we are capturing", and it exists because a
    /// notification that *succeeds* is a notification on the screen being
    /// shared. The audible half of that leak is the one that cannot be seen
    /// coming: a sharer capturing system audio is capturing the system mix,
    /// and the exclusion every platform offers drops only *our own* process's
    /// audio — a notification ding is played by the notification daemon, so it
    /// is somebody else's audio and it goes out on the wire. The sharer hears
    /// their own ding and has no way to know the viewers heard it too.
    ///
    /// Gating on the whole share rather than on "is system audio on" is
    /// deliberate. The narrower flag is togglable mid-share and mid-post, so
    /// it can be true between the decision and the sound; and the thing it
    /// would buy back is a ding for a person who is, by definition, sitting in
    /// front of the machine presenting. The banner is the notification.
    ///
    /// Note this only ever changes anything for `requestToShare`: the other
    /// four kinds exist only *during* a share, so they are silent under this
    /// rule always. An invitation arriving at an idle machine is the one
    /// notice with nothing to leak into and the best reason to be heard.
    public static func playsSound(isCapturing: Bool) -> Bool {
        !isCapturing
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
