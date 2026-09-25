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

/// The reconcile loop between live rows and posted notices, extracted from
/// the two swift-cross-ui hosts' `SharerNotifications`, whose `applyAsk` and
/// `applyViewers` were byte-identical.
///
/// Owns the `announced` bookkeeping (who's been told, per kind, with the
/// label for if they leave) and the order of operations: withdraw the gone,
/// post the fresh, remember the rest. Deliberately does NOT own delivery,
/// press routing (platform-specific), or the teardown rule that `reset()`
/// runs BEFORE rosters clear — the host calls it from `stop()`, since
/// stopping a share expels everyone at once and reconciling against the
/// resulting empty list would fire one "stopped watching" per viewer right
/// as the sharer decided to stop.
///
/// macOS isn't on this yet: `AppState` keeps four per-source notified-sets
/// and calls the decision functions directly, so folding it in is a
/// follow-up rather than a byte-identical extraction.
@MainActor
public struct SharerNoticeReconciler {
    /// Who has already been notified, per kind, with the name to use if they
    /// leave. The label is carried because a departure notice needs it after
    /// the peer is gone from every live list.
    private var announced: [SharerNoticeKind: [String: String]] = [:]

    public init() {}

    /// Reconcile the notifications for one *ask* kind against its live list.
    /// New rows are announced; rows that left have their banner taken back —
    /// not tidiness, since a stale "waiting to be let in" banner with a dead
    /// Accept button is actively wrong once admitted from the window.
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

    /// Reconcile the joined/left pair against the connected roster. Matched
    /// pair on purpose: a sharer told someone arrived but never told they
    /// left has to go check the app, which is the problem notifications
    /// exist to remove. Only viewers whose ARRIVAL was announced get a
    /// departure; nothing posts during teardown since `stop()` calls
    /// `reset()` first.
    public mutating func applyViewers(_ candidates: [NoticeCandidate], poster: NoticePosting) {
        let known = announced[.viewerJoined] ?? [:]
        let gone = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: Set(known.keys))
        for identity in gone {
            // Arrival banner goes; departure banner replaces it — leaving
            // "started watching" on screen after they left is what this
            // pair exists to prevent.
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
    /// itself, so a genuinely fresh ask is announced again. (Windows needs
    /// this: a press arrives through app activation, outside any reconcile
    /// pass.)
    public mutating func forget(kind: SharerNoticeKind, identity: String) {
        announced[kind]?.removeValue(forKey: identity)
    }

    /// Forget everybody. Call BEFORE rosters clear (see type doc), alongside
    /// whatever bulk withdraw the platform offers; clearing first makes the
    /// empty snapshots that follow no-ops.
    public mutating func reset() {
        announced.removeAll()
    }
}
