import Foundation
import UserNotifications

/// The app's `UNUserNotificationCenterDelegate`, and the place a notification
/// button press comes back to.
///
/// Without a delegate, a notification posted while Tailscreen is frontmost
/// displays **nothing at all** — the system's default for a foreground app is
/// to suppress it, and `add(_:)` reports success either way. There was no
/// delegate anywhere in the target, so every post made while the user had the
/// app in front was silently dropped: exactly the moment someone has just
/// clicked the menubar item and a viewer arrives.
///
/// The same object receives `didReceive response:`, which is the only way an
/// actionable notification reports which button was pressed. That half is
/// deliberately thin — it turns two opaque strings back into a
/// `(SharerNoticeKind, identity, NoticeAction)` triple and hands it to
/// `AppState`, which owns every one of those decisions already.
///
/// Stateless, so `@unchecked Sendable` costs nothing to guarantee — it exists
/// only to satisfy the `static let shared` a delegate needs in order to be
/// retained (`UNUserNotificationCenter.delegate` is weak).
///
/// The protocol conformance lives in the extension below rather than on this
/// line, so the declaration fits on one line: swift-format wraps a longer one
/// and puts the opening brace on its own line, which swiftlint's
/// `opening_brace` rule rejects — the two tools cannot both be satisfied by a
/// wrapped declaration, so the fix is to not need one. Same reasoning as
/// `AccountProfileStore.init`'s `fm` local.
final class TailscreenNotificationDelegate: NSObject, @unchecked Sendable {
    static let shared = TailscreenNotificationDelegate()

    /// Install once at launch. No-op on unbundled builds, where
    /// `UNUserNotificationCenter.current()` raises rather than degrading.
    ///
    /// Registering the categories here rather than at first post is not
    /// tidiness: a notification whose `categoryIdentifier` names a category
    /// the system has not seen is delivered **without its buttons**, with no
    /// error anywhere. Since categories are process-global state and posts can
    /// arrive within a second of launch, the only safe time to register them
    /// is before anything can post.
    @MainActor
    static func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(SharerNoticeCenter.categories())
    }
}

extension TailscreenNotificationDelegate: UNUserNotificationCenterDelegate {
    /// Show banners even when Tailscreen is the active app. `.list` keeps it
    /// in Notification Center so a sharer who looks away mid-share can still
    /// find out somebody is waiting; `.sound` is honoured only for posts that
    /// asked for one, and a post made during a share deliberately does not
    /// (see `SharerNoticeDecision.playsSound`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// A button was pressed, or the banner itself was clicked or dismissed.
    ///
    /// Everything needed to route this is read out of `response` **before** the
    /// hop to the MainActor: `UNNotificationResponse` is a non-`Sendable` class
    /// and this callback arrives on UN's own queue, so only the two `String`s
    /// cross. `completionHandler` is called synchronously rather than from
    /// inside the `Task` for the same reason — it is not a `@Sendable` closure,
    /// and the system only needs to know we accepted the response, not that we
    /// finished acting on it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let noticeID = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            TailscreenNotificationDelegate.route(
                noticeID: noticeID, actionIdentifier: actionIdentifier)
        }
        completionHandler()
    }

    /// Turn the daemon's two strings back into a decision and deliver it.
    ///
    /// Three outcomes, and the split between the first two is the whole point
    /// of keeping the action *key* distinct from the button *label*:
    ///
    ///   * one of our own keys (`NoticeAction.rawValue`) → the sharer answered,
    ///     so `AppState` acts on it;
    ///   * the system's "user clicked the banner body" identifier → not an
    ///     answer, so it opens the surface where the decision lives and lets
    ///     them look at it first;
    ///   * anything else, including the system's dismiss identifier and any id
    ///     this build did not mint → nothing at all. Swiping a banner away must
    ///     never be recorded as a decision about a person.
    @MainActor
    static func route(noticeID: String, actionIdentifier: String) {
        guard let decoded = SharerNotice.decodeID(noticeID) else { return }
        guard let appState = ViewerCommands.shared.appState else { return }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            appState.presentNoticeSurface(kind: decoded.kind)
            return
        }
        // `NoticeAction(rawValue:)` and not a title comparison: titles are
        // localized, so matching on them works in English and drops every
        // press in every other language.
        guard let action = NoticeAction(rawValue: actionIdentifier), action != .dismiss else {
            return
        }
        appState.handleNoticeAction(kind: decoded.kind, identity: decoded.identity, action: action)
    }
}
