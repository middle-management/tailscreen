import Foundation
import TailscaleKit
import UserNotifications

// The "Require approval for new viewers" preference is the portable
// `ViewerApprovalPreference` (TailscreenProtocol), shared with GTK/Windows.

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Notifications] \(message)")
    }
}

/// `UNUserNotificationCenter` delivery for `SharerNotice` — all five kinds,
/// one code path.
///
/// Decisions (which candidates get a banner, which break through Focus, which
/// offer buttons, what a press is called) come from `TailscreenProtocol`. The
/// words don't: every string here routes through `L(_:)`, and
/// `SharerNoticeText` (freedesktop's English source) is never consulted.
/// Button *label* is localized; button *key* is `NoticeAction.rawValue` and
/// must stay stable — separate arguments to `UNNotificationAction`, and
/// `TailscreenNotificationDelegate` reads back only the identifier.
///
/// Unbundled dev builds (no `CFBundleIdentifier`) can't use
/// `UNUserNotificationCenter` at all — `current()` raises rather than
/// degrading — so posting short-circuits on no bundle id. In-app pending
/// lists still show every row.
@MainActor
final class SharerNoticeCenter {
    static let shared = SharerNoticeCenter()
    private var didRequestAuthorization = false
    private let isBundled = Bundle.main.bundleIdentifier != nil

    /// Four states, not a `Bool`: "not asked yet" and "user said no" must not
    /// collapse to the same value. `authorized` is necessary but not
    /// sufficient — it says nothing about Focus filtering, Time Sensitive
    /// revocation, or alert style set to None, so the UI built on this only
    /// ever renders the negative.
    enum Authorization: Sendable, Equatable {
        case unknown
        case authorized
        /// Permanent until changed in System Settings.
        case denied
        /// Unbundled dev build; no prompt will ever be shown.
        case unavailable
    }

    private(set) var authorization: Authorization

    /// A callback, not `ObservableObject`: this is a plain notification
    /// wrapper, and `AppState` is what views actually watch.
    var onAuthorizationChanged: ((Authorization) -> Void)?

    private init() {
        authorization = Bundle.main.bundleIdentifier == nil ? .unavailable : .unknown
    }

    private func setAuthorization(_ value: Authorization) {
        guard authorization != value else { return }
        authorization = value
        onAuthorizationChanged?(value)
    }

    /// `isCapturing` is the sound gate, passed by the caller since only
    /// `AppState` knows (see `SharerNoticeDecision.playsSound`).
    func post(_ notice: SharerNotice, isCapturing: Bool) {
        guard isBundled else { return }
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: notice.kind)
        content.body = Self.body(for: notice)
        if SharerNoticeDecision.playsSound(isCapturing: isCapturing) {
            content.sound = .default
        }
        // `.timeSensitive` breaks through Focus/DND without needing the
        // `.critical` entitlement; a join is a report, not an ask, so it
        // stays at the default level.
        content.interruptionLevel = notice.kind.blocksSomeone ? .timeSensitive : .active
        content.categoryIdentifier = Self.categoryIdentifier(for: notice.kind)
        // `notice.id`, not a fresh UUID: re-posting replaces the banner in
        // place, and it's the only thing `didReceive` can decode back to the peer.
        let req = UNNotificationRequest(
            identifier: notice.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// A notice answered elsewhere (hub window, popover, peer gave up) must
    /// not outlive the decision — a stale "Accept/Deny" reads as a broken button.
    func withdraw(kind: SharerNoticeKind, identities: [String]) {
        guard isBundled, !identities.isEmpty else { return }
        // Round-tripped through `SharerNotice`, not formatted directly here,
        // so posting and withdrawing can't disagree about the identifier.
        let ids = identities.map { SharerNotice(kind: kind, identity: $0, label: "").id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - Words (macOS-local, localized)

    /// Says nothing about *who* — that's the body's job.
    private static func title(for kind: SharerNoticeKind) -> String {
        switch kind {
        case .viewerPending: L("Viewer Wants to Connect")
        case .controlRequested: L("Viewer Wants Control")
        case .requestToShare: L("Tailscreen request")
        case .viewerJoined: L("Viewer Connected")
        case .viewerLeft: L("Viewer Disconnected")
        }
    }

    private static func body(for notice: SharerNotice) -> String {
        let label = notice.label
        switch notice.kind {
        case .viewerPending: return L("\(label) is asking to view your screen.")
        case .controlRequested: return L("\(label) is asking to control your Mac.")
        case .requestToShare: return L("\(label) wants you to share your screen")
        case .viewerJoined: return L("\(label) is now viewing your screen.")
        case .viewerLeft: return L("\(label) stopped viewing your screen.")
        }
    }

    // MARK: - Categories and buttons

    /// Registered once with the system rather than attached per-post. Empty
    /// identifier for the two informational kinds gets no buttons.
    static func categoryIdentifier(for kind: SharerNoticeKind) -> String {
        kind.actions.isEmpty ? "" : "tailscreen.notice.\(kind.rawValue)"
    }

    /// For `setNotificationCategories` at launch. The affirmative is worded
    /// per kind (Accept/Grant/Share); only labels vary, keys are the shared
    /// `NoticeAction` raw values.
    static func categories() -> Set<UNNotificationCategory> {
        var categories: Set<UNNotificationCategory> = []
        for kind in SharerNoticeKind.allCases where !kind.actions.isEmpty {
            let actions = kind.actions.compactMap { action -> UNNotificationAction? in
                guard let title = label(for: action, kind: kind) else { return nil }
                return UNNotificationAction(
                    identifier: action.rawValue, title: title, options: options(for: action))
            }
            categories.insert(
                UNNotificationCategory(
                    identifier: categoryIdentifier(for: kind),
                    actions: actions,
                    intentIdentifiers: [],
                    options: []))
        }
        return categories
    }

    /// `nil` for an action never drawn as a button — `dismiss` is synthesized
    /// from the system's "swiped away" identifier, never offered.
    private static func label(for action: NoticeAction, kind: SharerNoticeKind) -> String? {
        switch (action, kind) {
        case (.approve, .viewerPending): return L("Accept")
        case (.approve, .controlRequested): return L("Grant")
        case (.approve, .requestToShare): return L("Share")
        case (.deny, .requestToShare): return L("Decline")
        case (.deny, _): return L("Deny")
        case (.approve, _), (.dismiss, _): return nil
        }
    }

    /// Approving needs an unlocked Mac (notification actions can fire from
    /// the lock screen); denying is the fail-safe answer, left unguarded.
    private static func options(for action: NoticeAction) -> UNNotificationActionOptions {
        guard action == .approve else { return [] }
        return [.authenticationRequired]
    }

    private func ensureAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        // Explicit `@Sendable`: this callback fires on UN's own service queue,
        // and without it the compiler infers MainActor isolation (this class
        // is @MainActor), which traps at runtime (dispatch_assert_queue_fail)
        // the first time a viewer joins.
        let record: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in
            Task { @MainActor in
                SharerNoticeCenter.shared.setAuthorization(granted ? .authorized : .denied)
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound], completionHandler: record)
    }

    /// Call at share start: a sharer whose prompts will never appear should
    /// be told by the app, not discover it by stranding somebody.
    func refreshAuthorization() {
        guard isBundled else { return }
        // @Sendable for the same reason as `ensureAuthorization`'s handler.
        let apply: @Sendable (UNNotificationSettings) -> Void = { settings in
            // `.notDetermined` stays `unknown` — only an explicit refusal warns.
            let state: Authorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = .authorized
            case .denied: state = .denied
            case .notDetermined: state = .unknown
            @unknown default: state = .unknown
            }
            if state == .denied {
                TSLogger().log(
                    "Notifications denied — viewer approval prompts will only appear in the app")
            }
            Task { @MainActor in SharerNoticeCenter.shared.setAuthorization(state) }
        }
        UNUserNotificationCenter.current().getNotificationSettings(completionHandler: apply)
    }
}
