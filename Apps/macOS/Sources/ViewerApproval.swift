import Foundation
import TailscaleKit
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

/// Per-file logger, following the convention the other mac sources use —
/// `LogSink` comes from TailscaleKit but each file declares its own private
/// conformer with its own prefix, so there is no shared `TSLogger` to import.
private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Notifications] \(message)")
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

    /// Whether macOS will actually display what we post. Starts optimistic —
    /// nothing is known until the first `requestAuthorization` or
    /// `refreshAuthorization` answers, and claiming "notifications are off"
    /// before asking would be its own lie.
    private(set) var isAuthorized = true

    private init() {}

    func postJoined(label: String) {
        post(
            prefix: "tailscreen.viewer.joined",
            title: L("Viewer Connected"),
            body: L("\(label) is now viewing your screen."),
            blocksSomeone: false)
    }

    func postPending(label: String) {
        post(
            prefix: "tailscreen.viewer.pending",
            title: L("Viewer Wants to Connect"),
            body: L("\(label) is asking to view your screen. Open Tailscreen to Accept or Deny."),
            blocksSomeone: true)
    }

    func postControlRequested(label: String) {
        post(
            prefix: "tailscreen.control.requested",
            title: L("Viewer Wants Control"),
            body: L("\(label) is asking to control your Mac. Open Tailscreen to Grant or Deny."),
            blocksSomeone: true)
    }

    /// One post path for all three, so the delivery decisions below can't
    /// drift between them the way `.interruptionLevel` did — three
    /// near-identical copies is how one of them ends up different.
    ///
    /// **No sound.** Every notice here fires *during* a share, and with system
    /// audio shared the helper captures the system mix.
    /// `excludesCurrentProcessAudio` drops only Tailscreen's own audio, and a
    /// notification sound is played by another process — so a `.default` sound
    /// here is a sound every viewer hears. The banner is the notification; the
    /// ding was leaking the fact that one arrived.
    ///
    /// `blocksSomeone` decides whether the notice outranks a Focus. It is the
    /// same split `SharerNoticeKind.blocksSomeone` makes in the portable tier;
    /// this reimplements it locally so the two changes stay independently
    /// reviewable, and should be replaced by that type when the actionable
    /// notifications land.
    private func post(prefix: String, title: String, body: String, blocksSomeone: Bool) {
        guard isBundled else { return }
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // A viewer parked at the approval gate cannot proceed until the sharer
        // answers, and "require approval" defaults on — so the person most
        // likely to be running a presentation Focus is exactly the person most
        // likely to have somebody blocked on them. `.timeSensitive` breaks
        // through Focus and Do Not Disturb and needs no entitlement (that is
        // `.critical`); the user can still revoke it per-app. A viewer *join*
        // is a report, not an ask, so it stays at the default level.
        content.interruptionLevel = blocksSomeone ? .timeSensitive : .active
        let req = UNNotificationRequest(
            identifier: "\(prefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func ensureAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        // UNUserNotificationCenter invokes this completion on its own service
        // queue, but `requestAuthorization`'s handler isn't `@Sendable`, so the
        // compiler infers it as MainActor-isolated (this class is @MainActor).
        // Swift 6's runtime then traps on the off-main executor check
        // (dispatch_assert_queue_fail → SIGTRAP) the first time a viewer joins.
        // Typing the closure `@Sendable` makes it non-isolated so it runs on
        // UN's queue with no executor assertion.
        //
        // The result is no longer discarded: a denial is permanent and
        // otherwise completely silent — every later post is accepted by the
        // API and displays nothing, so the sharer believes they are being
        // told about waiting viewers and is not. `isAuthorized` lets a caller
        // say so; `TailscreenNotificationDelegate` is what makes an
        // authorized post actually appear.
        let record: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in
            Task { @MainActor in ViewerJoinNotifier.shared.isAuthorized = granted }
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound], completionHandler: record)
    }

    /// Re-read the system's current authorization, which the user can change
    /// in System Settings at any time after the one-shot prompt. Call at share
    /// start: a sharer whose approval prompts will never appear should be told
    /// that by the app, not discover it by stranding somebody.
    func refreshAuthorization() {
        guard isBundled else { return }
        // Explicitly `@Sendable` for the same reason `ensureAuthorization`'s
        // handler is: this closure also runs on UN's own service queue, and
        // leaving the compiler to infer MainActor isolation from the enclosing
        // type makes Swift 6 trap on the executor check at runtime rather than
        // complain at compile time. `authorizationStatus` is read here, on
        // that queue, so only a `Bool` crosses to the MainActor —
        // `UNNotificationSettings` never does.
        let apply: @Sendable (UNNotificationSettings) -> Void = { settings in
            let granted =
                settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            if !granted {
                // The whole point of reading this back. Approval defaults on,
                // so without banners the sharer's only sign that somebody is
                // waiting is a row in a popover they have no reason to open.
                TSLogger().log(
                    "Notifications not authorized (status=\(settings.authorizationStatus.rawValue))"
                        + " — viewer approval prompts will only appear in the app")
            }
            Task { @MainActor in ViewerJoinNotifier.shared.isAuthorized = granted }
        }
        UNUserNotificationCenter.current().getNotificationSettings(completionHandler: apply)
    }
}
