import Foundation

/// What a notification backend does when the reconciler decides something
/// should appear or go away. The two swift-cross-ui hosts satisfy it with
/// their platform's delivery — freedesktop `Notify`/`CloseNotification` ids on
/// Linux, App SDK toast tags on Windows — and everything above the seam is
/// this file.
///
/// `@MainActor` because both hosts drive their notifier from the UI thread
/// (on Linux that is a hard requirement: GDBus delivers button presses to the
/// thread-default main context captured at subscribe time).
@MainActor
public protocol NoticePosting: AnyObject {
    /// Put one notice on screen (replacing any live banner with the same
    /// `SharerNotice.id`).
    func post(_ notice: SharerNotice)
    /// Take back the banner for `identity` under `kind`, if one is live.
    func withdraw(kind: SharerNoticeKind, identity: String)
}

/// The reconcile loop between live rows and posted notices, extracted from the
/// two swift-cross-ui hosts' `SharerNotifications`, whose `applyAsk` and
/// `applyViewers` were byte-identical — the classic sign that the sequencing
/// belonged beside the decision (`SharerNoticeDecision`) rather than in every
/// backend.
///
/// What it owns is the `announced` bookkeeping — who has been told about, per
/// kind, with the label to use if they leave — and the order of operations:
/// withdraw the gone, post the fresh, remember the rest. What it deliberately
/// does NOT own is delivery (the poster's), the routing of a button press back
/// (each platform hands presses back differently), and the teardown rule that
/// `reset()` runs BEFORE the rosters clear — the host calls it from its
/// `stop()`, because stopping a share expels every viewer at once and
/// reconciling against the resulting empty list would fire one "stopped
/// watching" banner per viewer at the exact moment the sharer already decided
/// to stop.
///
/// The macOS path is deliberately not on this yet: `AppState` keeps four
/// per-source notified-sets and calls the decision functions directly (its
/// withdraw rides `SharerNoticeCenter` by identifier, and one of its sets
/// deliberately survives `stopSharing`), so folding it in is a follow-up
/// rather than a byte-identical extraction like the two hosts above.
@MainActor
public struct SharerNoticeReconciler {
    /// Who has already been notified, per kind, with the name to use if they
    /// leave. The label is carried because a departure notice needs it after
    /// the peer is gone from every live list.
    private var announced: [SharerNoticeKind: [String: String]] = [:]

    public init() {}

    /// Reconcile the notifications for one *ask* kind against its live list.
    ///
    /// New rows are announced; rows that left have their banner taken back.
    /// That second half is not tidiness: a banner reading "someone is waiting
    /// to be let in", with an Accept button, is actively wrong once they have
    /// been admitted from the window — pressing it then does nothing.
    public mutating func applyAsk(
        kind: SharerNoticeKind, candidates: [NoticeCandidate], poster: NoticePosting
    ) {
        let known = announced[kind] ?? [:]
        let gone = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: Set(known.keys))
        for identity in gone { poster.withdraw(kind: kind, identity: identity) }

        let (fresh, remaining) = SharerNoticeDecision.noticesToPost(
            kind: kind, candidates: candidates, alreadyNotified: Set(known.keys))
        for notice in fresh { poster.post(notice) }
        announced[kind] = Dictionary(
            uniqueKeysWithValues: candidates.filter { remaining.contains($0.identity) }
                .map { ($0.identity, $0.label) })
    }

    /// Reconcile the joined/left pair against the connected roster.
    ///
    /// A matched pair on purpose: a sharer told somebody arrived and never told
    /// they left has to go and look to find out whether anyone is still
    /// watching, which is the ask-the-app problem notifications exist to
    /// remove. Only viewers whose ARRIVAL was announced get a departure —
    /// which falls out of reconciling against the same set — and nothing is
    /// posted during teardown, because the host's `stop()` calls `reset()`
    /// first.
    public mutating func applyViewers(_ candidates: [NoticeCandidate], poster: NoticePosting) {
        let known = announced[.viewerJoined] ?? [:]
        let gone = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: Set(known.keys))
        for identity in gone {
            // The arrival banner goes; a departure banner replaces it. Leaving
            // "started watching" on screen after they left is the one thing
            // this pair exists to prevent.
            poster.withdraw(kind: .viewerJoined, identity: identity)
            poster.post(
                SharerNotice(
                    kind: .viewerLeft, identity: identity, label: known[identity] ?? identity))
        }

        let (fresh, remaining) = SharerNoticeDecision.noticesToPost(
            kind: .viewerJoined, candidates: candidates, alreadyNotified: Set(known.keys))
        for notice in fresh { poster.post(notice) }
        announced[.viewerJoined] = Dictionary(
            uniqueKeysWithValues: candidates.filter { remaining.contains($0.identity) }
                .map { ($0.identity, $0.label) })
    }

    /// Drop one identity after its banner was answered from the notification
    /// itself, so a genuinely fresh ask from the same peer is announced again.
    /// (The Windows host needs this: a press arrives through app activation,
    /// outside any reconcile pass.)
    public mutating func forget(kind: SharerNoticeKind, identity: String) {
        announced[kind]?.removeValue(forKey: identity)
    }

    /// Forget everybody. Call BEFORE the rosters are cleared — see the type
    /// comment — and alongside whatever bulk withdraw the platform offers;
    /// clearing first is what makes the empty snapshots that follow no-ops.
    public mutating func reset() {
        announced.removeAll()
    }
}
