import Foundation
import UserNotifications

/// Persisted flag for the "Require approval for new viewers" toggle.
/// Plain `UserDefaults` so non-SwiftUI call sites (`AppState.init`'s
/// stored-property initialiser) can read the saved value without going
/// through `@AppStorage`, which is `@MainActor`-bound and awkward to
/// reference from a property default.
///
/// The gate defaults **on**: a tri-state read (`object(forKey:)`) tells a
/// never-touched install (`nil` → `true`) apart from an explicit opt-out
/// (stored `false`). Users who ever flipped the toggle have a stored Bool
/// (AppState's `didSet` persists every change) and keep their choice — the
/// migration is free.
///
/// `TAILSCREEN_OPEN_DOOR=1` forces the gate off regardless of the stored
/// value. It exists for the scripted local E2E harness and `test-local.sh`,
/// whose automated viewers would otherwise park on the approval prompt with
/// nobody around to click Accept. Never set it in production.
enum ViewerApprovalDefaults {
    static let key = "requireViewerApproval"
    static let openDoorEnvKey = "TAILSCREEN_OPEN_DOOR"

    static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[openDoorEnvKey] == "1" {
            return false
        }
        guard let stored = defaults.object(forKey: key) as? Bool else {
            return true
        }
        return stored
    }

    static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
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
/// Authorization is requested on first use. Unbundled dev builds (no
/// `CFBundleIdentifier`) can't use `UNUserNotificationCenter` at all —
/// `current()` raises `NSInternalInconsistencyException` rather than
/// returning a degraded instance — so we short-circuit when there's no
/// bundle id. The in-popover SharingCard UI still shows pending rows.
@MainActor
final class ViewerJoinNotifier {
    static let shared = ViewerJoinNotifier()
    private var didRequestAuthorization = false
    private let isBundled = Bundle.main.bundleIdentifier != nil

    private init() {}

    func postJoined(label: String) {
        guard isBundled else { return }
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = L("Viewer Connected")
        content.body = L("\(label) is now viewing your screen.")
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "tailscreen.viewer.joined.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func postPending(label: String) {
        guard isBundled else { return }
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = L("Viewer Wants to Connect")
        content.body = L("\(label) is asking to view your screen. Open Tailscreen to Accept or Deny.")
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
