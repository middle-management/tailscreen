import Foundation
import GNotifyKit

import enum TailscreenProtocol.SharerNoticeKind
import enum TailscreenProtocol.SharerNoticeText
import protocol TailscreenProtocol.NoticePosting
import struct TailscreenProtocol.NoticeCandidate
import struct TailscreenProtocol.SharerNotice
import struct TailscreenProtocol.SharerNoticeReconciler

/// Posts the sharer's notifications, and routes their buttons back.
///
/// The surface that reaches somebody whose attention is on the thing they are
/// sharing. During a share this app's window is BEHIND the shared content, and
/// raising it is itself visible to the viewers — so every mid-share ask costs
/// an interruption they can see. Worse, "Require approval for new viewers"
/// defaults on: a sharer who is not looking silently strands whoever tries to
/// connect, with nothing on screen to notice.
///
/// Deliberately thin — a backend adapter. Which notices to post, which to take
/// back, and what they say is `SharerNoticeReconciler` / `SharerNoticeText` in
/// `TailscreenProtocol`, tested on Linux CI; delivery is `GNotifyKit`, gated
/// against a real daemon. What is left here is bookkeeping: which daemon id
/// belongs to which peer.
///
/// `@MainActor` because `DesktopNotifier` must be built on the thread whose
/// `GMainContext` is iterated — GDBus captures that at subscribe time, and a
/// notifier built anywhere else posts perfectly and reports no button press
/// ever. In this app that thread is GTK's main thread.
@MainActor
final class SharerNotifications: NoticePosting {
    /// Nil when there is no session bus or no notification daemon — a headless
    /// box, a minimal session, a container. A normal state: the hub keeps its
    /// in-window prompts and nothing is said.
    private let notifier: DesktopNotifier?

    /// The announce/withdraw bookkeeping, shared with the Windows host — this
    /// type is the `NoticePosting` half it drives.
    private var reconciler = SharerNoticeReconciler()
    /// Live banners, so they can be taken back: `SharerNotice.id` → daemon id.
    private var posted: [String: UInt32] = [:]
    /// The reverse, for routing a button press: daemon id → what it was about.
    private var routes: [UInt32: (kind: SharerNoticeKind, identity: String)] = [:]

    /// A button was pressed. `identity` is whatever the caller put in the
    /// candidate — `"ip:port"` for a pending viewer, a UUID string for the two
    /// request kinds — so the host can route it without re-deriving anything.
    var onAnswer: ((SharerNoticeKind, String, Bool) -> Void)?

    init() {
        notifier = DesktopNotifier()
        if notifier == nil {
            // stderr rather than an alert: there is nothing the user can do
            // about it from here, and a machine with no notification daemon is
            // not misconfigured.
            FileHandle.standardError.write(
                Data(
                    """
                    note: no desktop notifications (\(DesktopNotifier.openError ?? "unknown")) — \
                    approvals appear in the window only\n
                    """.utf8))
            return
        }
        notifier?.onAction = { [weak self] id, key in
            // Fires on GTK's main thread, which is the main actor's — the same
            // assumption the annotation overlay's callbacks make, and the
            // reason this type is main-actor in the first place.
            MainActor.assumeIsolated {
                guard let self, let route = self.routes[id] else { return }
                self.forget(daemonID: id)
                self.onAnswer?(route.kind, route.identity, key == SharerNoticeText.approveKey)
            }
        }
        notifier?.onClose = { [weak self] id, reason in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Dismissing a banner is NOT a decision about a peer. The row
                // stays in the window and the person is still waiting; all
                // that is lost is the shortcut.
                _ = reason
                self.forget(daemonID: id)
            }
        }
    }

    /// Whether anything will actually be posted. The hub uses this to say so.
    var isAvailable: Bool { notifier != nil }

    /// Whether the daemon can render buttons. False is a real state on several
    /// minimal daemons; the notice text changes to say where to answer, and
    /// the share card says so too (`SharerModel.notificationsLackActions`) —
    /// a banner stating a decision with no way to make it reads as broken
    /// otherwise.
    var rendersActions: Bool { notifier?.supportsActions ?? false }

    // MARK: Asks

    /// Reconcile the notifications for one *ask* kind against its live list —
    /// the shared reconciler's loop, with this type as its delivery.
    func applyAsk(kind: SharerNoticeKind, candidates: [NoticeCandidate]) {
        guard notifier != nil else { return }
        reconciler.applyAsk(kind: kind, candidates: candidates, poster: self)
    }

    // MARK: Reports

    /// Reconcile the joined/left pair against the connected roster — likewise
    /// the shared reconciler's, including the rule that only viewers whose
    /// arrival was announced get a departure.
    func applyViewers(_ candidates: [NoticeCandidate]) {
        guard notifier != nil else { return }
        reconciler.applyViewers(candidates, poster: self)
    }

    // MARK: Teardown

    /// Take every banner back and forget everybody.
    ///
    /// Called BEFORE the rosters are cleared, and that order is the whole
    /// point: stopping a share expels every viewer at once, so reconciling
    /// against the resulting empty list would fire one "stopped watching"
    /// banner per viewer at the exact moment the sharer already decided to
    /// stop. Clearing first makes the empty snapshot a no-op.
    func stop() {
        for id in posted.values { notifier?.withdraw(id) }
        posted.removeAll()
        routes.removeAll()
        reconciler.reset()
    }

    // MARK: Delivery (the `NoticePosting` half the reconciler drives)

    func post(_ notice: SharerNotice) {
        guard let notifier else { return }
        let text = SharerNoticeText.render(
            notice, rendersBody: notifier.supportsBody, rendersActions: notifier.supportsActions)
        guard
            let id = notifier.post(
                summary: text.summary,
                body: text.body,
                actions: text.buttons.map { .init(key: $0.key, label: $0.label) },
                // Only the two mid-share asks break through Do Not Disturb.
                // The exemption is revoked per APP, so spending it on an
                // invitation that arrives while the machine is idle is how it
                // gets taken away from the ones where somebody is stuck.
                urgency: notice.kind.blocksSomeone ? .critical : .normal,
                replacing: posted[notice.id] ?? 0,
                // An ask that times out silently leaves the person on the other
                // end waiting forever with nobody aware of it. A report can go.
                expiresAutomatically: notice.kind.actions.isEmpty)
        else { return }
        posted[notice.id] = id
        routes[id] = (notice.kind, notice.identity)
    }

    func withdraw(kind: SharerNoticeKind, identity: String) {
        let key = SharerNotice(kind: kind, identity: identity, label: "").id
        guard let id = posted.removeValue(forKey: key) else { return }
        routes.removeValue(forKey: id)
        notifier?.withdraw(id)
    }

    /// Drop the bookkeeping for a banner that is no longer on screen, without
    /// asking the daemon to close something it already closed.
    private func forget(daemonID: UInt32) {
        guard let route = routes.removeValue(forKey: daemonID) else { return }
        posted.removeValue(
            forKey: SharerNotice(kind: route.kind, identity: route.identity, label: "").id)
    }
}
