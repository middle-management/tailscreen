import Foundation
import UserNotifications

/// Persisted flag for the "Require approval for new viewers" toggle.
/// Plain `UserDefaults` so non-SwiftUI call sites (`AppState.init`'s
/// stored-property initialiser) can read the saved value without going
/// through `@AppStorage`, which is `@MainActor`-bound and awkward to
/// reference from a property default.
enum ViewerApprovalDefaults {
    static let key = "requireViewerApproval"

    static func load() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func save(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// Thin wrapper around `UNUserNotificationCenter` for the
/// viewer-connection feature. Two surfaces:
///
///   * `postJoined(label:)` — fired the moment a viewer's video starts
///     flowing (open-door mode, or post-Accept in approval mode).
///   * `postPending(label:)` — fired when a viewer arrives while the
///     approval gate is on and is now waiting on the sharer's decision.
///
/// Authorization is requested on first use. macOS rejects unbundled
/// development builds (no `CFBundleIdentifier`) silently, in which case
/// the notification just doesn't appear; the in-popover SharingCard UI
/// still shows the pending viewer rows, so the feature degrades.
@MainActor
final class ViewerJoinNotifier {
    static let shared = ViewerJoinNotifier()
    private var didRequestAuthorization = false

    private init() {}

    func postJoined(label: String) {
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "Viewer Connected"
        content.body = "\(label) is now viewing your screen."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "tailscreen.viewer.joined.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func postPending(label: String) {
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "Viewer Wants to Connect"
        content.body = "\(label) is asking to view your screen. Open Tailscreen to Accept or Deny."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "tailscreen.viewer.pending.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func ensureAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Best-effort: in dev builds without a bundle identifier the
            // call returns `notAuthorized`; we just don't show banners.
        }
    }
}
