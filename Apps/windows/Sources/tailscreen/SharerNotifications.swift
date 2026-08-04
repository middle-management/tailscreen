import Foundation
import WinNotifyKit

import enum TailscreenProtocol.NoticeAction
import struct TailscreenProtocol.NoticeCandidate
import struct TailscreenProtocol.SharerNotice
import enum TailscreenProtocol.SharerNoticeDecision
import enum TailscreenProtocol.SharerNoticeKind
import enum TailscreenProtocol.SharerNoticeText

/// Posts the sharer's notifications, and routes their buttons back.
///
/// The Windows twin of the GTK app's file of the same name, deliberately: the
/// surface exists for the same reason on both, and every decision behind it is
/// the same portable code. During a share this app's window is BEHIND the
/// shared content, and raising it is itself visible to the viewers — so every
/// mid-share ask costs an interruption they can see. Worse, "Require approval
/// for new viewers" defaults on: a sharer who is not looking silently strands
/// whoever tries to connect, with nothing on screen to notice.
///
/// What to post, what to take back, and what it says is
/// `SharerNoticeDecision` / `SharerNoticeText` in `TailscreenProtocol`;
/// delivery and the toast document are `WinNotifyKit`. What is left here is
/// bookkeeping.
///
/// **Two things differ from the GTK version, both because of the platform.**
/// A press comes back through `AppInstance.Activated` rather than a callback
/// on the notifier, so the host feeds it in through ``answer(activationID:)``
/// — and because that carries one opaque string, the notice's own `id` is what
/// rides along, with `SharerNotice.decodeID` reading it back. And there is no
/// "the banner was dismissed" signal at all, so a toast the user swipes away
/// stays in `posted` until the thing it is about ends. That is the harmless
/// direction: withdrawing something already gone is a no-op, while forgetting
/// a live banner would strand it on screen.
@MainActor
final class SharerNotifications {
    /// Nil when `Register()` was refused — no reachable Windows App Runtime,
    /// which is the expected state for an unpackaged zip run today. A normal
    /// state: the hub keeps its in-window prompts and says so on the card.
    private let notifier: WindowsNotifier?

    /// Who has already been notified, per kind, with the name to use if they
    /// leave. The label is carried because a departure notice needs it after
    /// the peer is gone from every live list.
    private var announced: [SharerNoticeKind: [String: String]] = [:]
    /// Live toasts, so they can be taken back: `SharerNotice.id` → tag.
    private var posted: [String: String] = [:]

    /// A button was pressed. `identity` is whatever the caller put in the
    /// candidate — `"ip:port"` for a pending viewer, a UUID string for the two
    /// request kinds — so the host can route it without re-deriving anything.
    var onAnswer: ((SharerNoticeKind, String, Bool) -> Void)?

    init() {
        notifier = WindowsNotifier(displayName: "Tailscreen")
        guard notifier == nil else { return }
        // stderr rather than an alert: there is nothing the user can do about
        // it from here, and a machine that cannot register is not
        // misconfigured. The share card says the part that matters.
        FileHandle.standardError.write(
            Data(
                """
                note: no desktop notifications (\(WindowsNotifier.openError ?? "unknown")) — \
                approvals appear in the window only\n
                """.utf8))
    }

    /// Whether anything will actually be posted. The hub uses this to say so.
    var isAvailable: Bool { notifier != nil }

    /// Whether a posted toast would be SEEN.
    ///
    /// Separate from `isAvailable` because the failure is separate and quieter:
    /// with notifications switched off for this app, `Show` still succeeds and
    /// the toast goes nowhere. Re-read on every access rather than cached, since
    /// a user can turn them off mid-share.
    var isVisible: Bool { notifier?.canBeSeen ?? false }

    // MARK: Asks

    /// Reconcile the notifications for one *ask* kind against its live list.
    ///
    /// New rows are announced; rows that left have their toast taken back.
    /// That second half is not tidiness: a toast reading "someone is waiting
    /// to be let in", with an Accept button, is actively wrong once they have
    /// been admitted from the window — pressing it then does nothing.
    func applyAsk(kind: SharerNoticeKind, candidates: [NoticeCandidate]) {
        guard notifier != nil else { return }
        let known = announced[kind] ?? [:]
        let gone = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: Set(known.keys))
        for identity in gone { withdraw(kind: kind, identity: identity) }

        let (fresh, remaining) = SharerNoticeDecision.noticesToPost(
            kind: kind, candidates: candidates, alreadyNotified: Set(known.keys))
        for notice in fresh { post(notice) }
        announced[kind] = Dictionary(
            uniqueKeysWithValues: candidates.filter { remaining.contains($0.identity) }
                .map { ($0.identity, $0.label) })
    }

    // MARK: Reports

    /// Reconcile the joined/left pair against the connected roster.
    ///
    /// A matched pair on purpose: a sharer told somebody arrived and never told
    /// they left has to go and look to find out whether anyone is still
    /// watching, which is the ask-the-app problem notifications exist to
    /// remove. Only viewers whose ARRIVAL was announced get a departure —
    /// which falls out of reconciling against the same set — and nothing is
    /// posted during teardown, because `stop()` clears the set first.
    func applyViewers(_ candidates: [NoticeCandidate]) {
        guard notifier != nil else { return }
        let known = announced[.viewerJoined] ?? [:]
        let gone = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: Set(known.keys))
        for identity in gone {
            // The arrival toast goes; a departure toast replaces it. Leaving
            // "started watching" on screen after they left is the one thing
            // this pair exists to prevent.
            withdraw(kind: .viewerJoined, identity: identity)
            post(
                SharerNotice(
                    kind: .viewerLeft, identity: identity, label: known[identity] ?? identity))
        }

        let (fresh, remaining) = SharerNoticeDecision.noticesToPost(
            kind: .viewerJoined, candidates: candidates, alreadyNotified: Set(known.keys))
        for notice in fresh { post(notice) }
        announced[.viewerJoined] = Dictionary(
            uniqueKeysWithValues: candidates.filter { remaining.contains($0.identity) }
                .map { ($0.identity, $0.label) })
    }

    // MARK: Activation

    /// A toast was activated, and AppLifecycle woke the app with it.
    ///
    /// `id` is the notice's own `id`, which the payload put in the activation
    /// string precisely so this needs no table that could go stale between
    /// posting and pressing. Nothing happens for a launch that was not ours,
    /// or for a press about a peer who is no longer in any list — the host's
    /// router matches against the live rows, so a stale answer lands nowhere
    /// rather than on whoever is there now.
    ///
    /// **`action` is checked against the two answer keys, never treated as a
    /// boolean.** Clicking the toast BODY activates the app too, with
    /// `openActionKey`, and reading that as a deny would decide about a peer
    /// because somebody looked at the notification. Anything that is not an
    /// explicit approve or deny is a no-op here: the app comes forward and the
    /// in-window prompt is still waiting.
    func answer(activationID id: String, action key: String) {
        let action = SharerNoticeText.action(forKey: key)
        guard action != .dismiss else { return }
        guard let (kind, identity) = SharerNotice.decodeID(id) else { return }
        // The toast goes as soon as it is answered. Windows leaves an actioned
        // toast in the Action Center otherwise, where pressing it again would
        // send the same answer about a peer who has already been dealt with.
        withdraw(kind: kind, identity: identity)
        announced[kind]?.removeValue(forKey: identity)
        onAnswer?(kind, identity, action == .approve)
    }

    // MARK: Teardown

    /// Take every toast back and forget everybody.
    ///
    /// Called BEFORE the rosters are cleared, and that order is the whole
    /// point: stopping a share expels every viewer at once, so reconciling
    /// against the resulting empty list would fire one "stopped watching"
    /// toast per viewer at the exact moment the sharer already decided to
    /// stop. Clearing first makes the empty snapshot a no-op.
    func stop() {
        // By group rather than tag by tag: one call, and it also collects any
        // toast whose bookkeeping was lost — the swiped-away case this
        // platform gives no signal for.
        notifier?.withdrawAll()
        posted.removeAll()
        announced.removeAll()
    }

    // MARK: Plumbing

    private func post(_ notice: SharerNotice) {
        guard let notifier else { return }
        // Windows renders both lines and always renders buttons, so neither of
        // the two freedesktop capability gaps applies — but the text still
        // comes from the shared renderer rather than being composed here, so
        // the three platforms cannot drift into three sets of words.
        let text = SharerNoticeText.render(notice, rendersBody: true, rendersActions: true)
        guard
            let tag = notifier.post(
                summary: text.summary,
                body: text.body,
                buttons: text.buttons.map { .init(key: $0.key, label: $0.label) },
                // The notice's own id, not its identity: it is what comes back
                // through AppLifecycle, and it has to say which KIND was
                // answered as well as about whom.
                identity: notice.id,
                // Only the two mid-share asks break through Focus Assist. The
                // exemption is revoked per APP, so spending it on an
                // invitation that arrives while the machine is idle is how it
                // gets taken away from the ones where somebody is stuck.
                blocksSomeone: notice.kind.blocksSomeone)
        else { return }
        posted[notice.id] = tag
    }

    private func withdraw(kind: SharerNoticeKind, identity: String) {
        let key = SharerNotice(kind: kind, identity: identity, label: "").id
        guard let tag = posted.removeValue(forKey: key) else { return }
        notifier?.withdraw(tag)
    }
}
