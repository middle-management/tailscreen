import Foundation
import UserNotifications

/// The app's `UNUserNotificationCenterDelegate`, and where a notification
/// button press comes back to.
///
/// Without a delegate, a notification posted while frontmost displays
/// **nothing at all** — the system suppresses it for a foreground app and
/// `add(_:)` reports success either way.
///
/// `@unchecked Sendable` costs nothing since it's stateless — only needed for
/// the `static let shared` a delegate needs to be retained (`.delegate` is weak).
final class TailscreenNotificationDelegate: NSObject, @unchecked Sendable {
    static let shared = TailscreenNotificationDelegate()

    /// No-op on unbundled builds, where `UNUserNotificationCenter.current()`
    /// raises. Registering categories here, not at first post: a notification
    /// whose `categoryIdentifier` names an unseen category is delivered
    /// without its buttons, silently, and posts can arrive within a second of
    /// launch.
    @MainActor
    static func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(SharerNoticeCenter.categories())
    }
}

extension TailscreenNotificationDelegate: UNUserNotificationCenterDelegate {
    /// `.list` keeps it in Notification Center; `.sound` is honored only for
    /// posts that asked for one (see `SharerNoticeDecision.playsSound`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Everything needed is read out of `response` before hopping to
    /// MainActor: `UNNotificationResponse` isn't `Sendable`, so only the two
    /// `String`s cross. `completionHandler` is called synchronously for the
    /// same reason — it's not `@Sendable`.
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

    /// Three outcomes: one of our own keys -> `AppState` acts on it; the
    /// system's "clicked the banner body" identifier -> opens the surface
    /// instead (checked before the key lookup, or it folds into `.dismiss`);
    /// anything else (including dismiss) -> nothing. Swiping a banner away
    /// must never record as a decision about a person.
    @MainActor
    static func route(noticeID: String, actionIdentifier: String) {
        guard let decoded = SharerNotice.decodeID(noticeID) else { return }
        guard let appState = ViewerCommands.shared.appState else { return }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            appState.presentNoticeSurface(kind: decoded.kind)
            return
        }
        let action = SharerNoticeText.action(forKey: actionIdentifier)
        guard action != .dismiss else { return }
        appState.handleNoticeAction(kind: decoded.kind, identity: decoded.identity, action: action)
    }
}
