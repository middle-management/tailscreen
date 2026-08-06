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

/// `UNUserNotificationCenter` delivery for `SharerNotice` — the whole sharer
/// notification surface, all five kinds, one code path.
///
/// **What is shared with the other platforms and what is not.** The *decisions*
/// come from `TailscreenProtocol`: which candidates are worth a banner
/// (`SharerNoticeDecision.noticesToPost`), which kinds break through a Focus
/// (`SharerNoticeKind.blocksSomeone`), which offer buttons
/// (`SharerNoticeKind.actions`), what a button press is called
/// (`NoticeAction.rawValue`), and whether anything may make a sound
/// (`SharerNoticeDecision.playsSound`). The *words* do not: macOS routes every
/// user-facing string through `L(_:)` (the shared TailscreenL10n catalog), so the titles,
/// bodies and button labels below are local and localized, and
/// `SharerNoticeText` — English source text for the freedesktop backend to
/// render — is deliberately not consulted for any of them.
///
/// That split is exactly where a button stops routing if it is drawn wrong.
/// The *label* on a button is localized and changes per language; the *key* it
/// reports back is `NoticeAction.rawValue` and must not. So the two are
/// separate arguments to `UNNotificationAction(identifier:title:)`, and
/// `TailscreenNotificationDelegate` reads back the identifier, never the title.
/// The keys here are the same constants `SharerNoticeText.approveKey` /
/// `denyKey` name for the freedesktop side — that type now derives them from
/// `NoticeAction` for exactly this reason, so the two backends cannot drift
/// into posting keys the other's router would not recognise.
///
/// Authorization is requested on first use. Unbundled dev builds (no
/// `CFBundleIdentifier`) can't use `UNUserNotificationCenter` at all —
/// `current()` raises `NSInternalInconsistencyException` rather than
/// returning a degraded instance — so we short-circuit when there's no
/// bundle id. The in-app pending lists still show every row.
@MainActor
final class SharerNoticeCenter {
    static let shared = SharerNoticeCenter()
    private var didRequestAuthorization = false
    private let isBundled = Bundle.main.bundleIdentifier != nil

    /// What we know about whether macOS will display what we post.
    ///
    /// Deliberately four states rather than a `Bool`, because "we have not
    /// asked yet" and "the user said no" must not be the same value — a UI
    /// that warns on the first is crying wolf, and one that stays quiet on the
    /// second is the exact confusion this exists to remove.
    ///
    /// Note what this can and cannot see. It knows about authorization; it
    /// knows nothing about a Focus filtering us, Time Sensitive being revoked,
    /// or the alert style being set to None. So `authorized` is **not** a
    /// promise that a banner will appear — which is why the UI built on this
    /// only ever renders the negative, and never claims notifications are
    /// working.
    enum Authorization: Sendable, Equatable {
        /// Not asked yet, so nothing is known.
        case unknown
        /// The user allowed it. Necessary, not sufficient — see above.
        case authorized
        /// The user said no. Permanent until they change it in System Settings.
        case denied
        /// Unbundled dev build; `UNUserNotificationCenter` is unusable here at
        /// all, and no prompt will ever be shown.
        case unavailable
    }

    private(set) var authorization: Authorization

    /// Fired whenever `authorization` changes, so `AppState` can mirror it into
    /// a `@Published` the views observe. A callback rather than making this
    /// type an `ObservableObject`: it is a plain notification wrapper, and
    /// `AppState` is already the thing every view watches.
    var onAuthorizationChanged: ((Authorization) -> Void)?

    private init() {
        authorization = Bundle.main.bundleIdentifier == nil ? .unavailable : .unknown
    }

    private func setAuthorization(_ value: Authorization) {
        guard authorization != value else { return }
        authorization = value
        onAuthorizationChanged?(value)
    }

    /// Post one notice.
    ///
    /// One path for all five kinds, so the delivery decisions below can't
    /// drift between them the way `.interruptionLevel` did — near-identical
    /// copies is how one of them ends up different.
    ///
    /// `isCapturing` is the sound gate, and it is the caller's because only
    /// `AppState` knows: see `SharerNoticeDecision.playsSound` for why a ding
    /// during a share is audible to every viewer.
    func post(_ notice: SharerNotice, isCapturing: Bool) {
        guard isBundled else { return }
        ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: notice.kind)
        content.body = Self.body(for: notice)
        if SharerNoticeDecision.playsSound(isCapturing: isCapturing) {
            content.sound = .default
        }
        // A viewer parked at the approval gate cannot proceed until the sharer
        // answers, and "require approval" defaults on — so the person most
        // likely to be running a presentation Focus is exactly the person most
        // likely to have somebody blocked on them. `.timeSensitive` breaks
        // through Focus and Do Not Disturb and needs no entitlement (that is
        // `.critical`); the user can still revoke it per-app. A viewer *join*
        // is a report, not an ask, so it stays at the default level.
        content.interruptionLevel = notice.kind.blocksSomeone ? .timeSensitive : .active
        // The category is what carries the buttons — an unregistered or empty
        // identifier renders a plain banner, which is the correct outcome for
        // the two informational kinds.
        content.categoryIdentifier = Self.categoryIdentifier(for: notice.kind)
        // `notice.id`, not a fresh UUID. Re-posting the same notice then
        // replaces the banner in place rather than stacking a second one, and
        // it is the only thing that survives the trip out to the notification
        // daemon and back — `didReceive` decodes it to find the peer.
        let req = UNNotificationRequest(
            identifier: notice.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Withdraw a notice that has been answered elsewhere — in the hub window,
    /// in the popover, or by the peer giving up.
    ///
    /// An actionable banner outlives what it is about. Left in Notification
    /// Center, an "Accept / Deny" for a viewer who is already watching invites
    /// a press that can only be a no-op, and reads as a broken button rather
    /// than as a stale one. Withdrawing costs nothing and is the honest
    /// counterpart to posting.
    func withdraw(kind: SharerNoticeKind, identities: [String]) {
        guard isBundled, !identities.isEmpty else { return }
        // Round-tripped through `SharerNotice` rather than by formatting
        // `"kind:identity"` here, so posting and withdrawing can't disagree
        // about the identifier. The label is unused in `id` — that is the only
        // reason the empty string is safe.
        let ids = identities.map { SharerNotice(kind: kind, identity: $0, label: "").id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - Words (macOS-local, localized)

    /// The short line. Says nothing about *who* — that is the body's job, and
    /// duplicating it reads as a stutter in a banner that shows both.
    private static func title(for kind: SharerNoticeKind) -> String {
        switch kind {
        case .viewerPending: L("Viewer Wants to Connect")
        case .controlRequested: L("Viewer Wants Control")
        case .requestToShare: L("Tailscreen request")
        case .viewerJoined: L("Viewer Connected")
        case .viewerLeft: L("Viewer Disconnected")
        }
    }

    /// The sentence naming the peer and what they want.
    ///
    /// The two asks used to end with "Open Tailscreen to Accept or Deny."
    /// That sentence was true when the banner had no buttons and is now an
    /// instruction to go the long way round past the two buttons directly
    /// underneath it.
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

    /// A notification's buttons come from its *category*, registered once with
    /// the system rather than attached per-post. One per actionable kind;
    /// the two informational kinds get the empty identifier and no buttons.
    static func categoryIdentifier(for kind: SharerNoticeKind) -> String {
        kind.actions.isEmpty ? "" : "tailscreen.notice.\(kind.rawValue)"
    }

    /// Every category the app can post under, for
    /// `setNotificationCategories` at launch.
    ///
    /// The affirmative is worded per kind rather than shared, matching the
    /// in-app control for the same decision: the pending row says Accept, the
    /// control request says Grant, and an invitation to start sharing is
    /// answered with Share — "Accept" is right for a viewer at the gate and
    /// limp for an invitation, where the answer is an action rather than
    /// agreement. Only the labels vary; both keys are the shared
    /// `NoticeAction` raw values, so one router handles all three.
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

    /// `nil` for an action that is never drawn as a button — `dismiss` is
    /// synthesized from the system's own "swiped away" identifier, never
    /// offered, because closing a banner must not read as a decision about a
    /// person.
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

    /// Approving needs an unlocked Mac; denying does not.
    ///
    /// macOS can show notification actions on the lock screen, and two of the
    /// three approvals here hand a stranger the screen or the pointer. The
    /// deny half is deliberately left unguarded: it is the fail-safe answer,
    /// and making the safe answer the harder one is how people learn to press
    /// the other one.
    private static func options(for action: NoticeAction) -> UNNotificationActionOptions {
        guard action == .approve else { return [] }
        return [.authenticationRequired]
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
        // told about waiting viewers and is not. `authorization` lets the UI
        // say so; `TailscreenNotificationDelegate` is what makes an
        // authorized post actually appear.
        let record: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in
            Task { @MainActor in
                SharerNoticeCenter.shared.setAuthorization(granted ? .authorized : .denied)
            }
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
            // `.notDetermined` stays `unknown`: the user has not been asked,
            // so there is nothing to warn them about yet. Only an explicit
            // refusal warns.
            let state: Authorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = .authorized
            case .denied: state = .denied
            case .notDetermined: state = .unknown
            @unknown default: state = .unknown
            }
            if state == .denied {
                // The whole point of reading this back. Approval defaults on,
                // so without banners the sharer's only sign that somebody is
                // waiting is a row in a popover they have no reason to open.
                TSLogger().log(
                    "Notifications denied — viewer approval prompts will only appear in the app")
            }
            Task { @MainActor in SharerNoticeCenter.shared.setAuthorization(state) }
        }
        UNUserNotificationCenter.current().getNotificationSettings(completionHandler: apply)
    }
}
