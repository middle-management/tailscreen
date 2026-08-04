import CWinNotify
import Foundation
import TailscreenProtocol

/// Desktop notifications on Windows, via the Windows App SDK's
/// `AppNotificationManager`.
///
/// The sibling of `GNotifyKit.DesktopNotifier` on Linux and
/// `UNUserNotificationCenter` on macOS, with deliberately the same surface:
/// construct, ask what the desktop can do, post, withdraw when the thing the
/// notice is about ends.
///
/// It exists for the row the plan calls the one case a sharer cannot afford to
/// miss. "Require approval for new viewers" defaults **on**, and during a share
/// the app window is behind the thing being shared — where raising it is itself
/// visible to viewers. So an unattended sharer strands whoever tries to
/// connect, with nothing on screen to notice.
///
/// What to say and when is `SharerNoticeDecision`'s; the words are
/// `SharerNoticeText`'s; the XML is `WindowsToastPayload`'s. All three are in
/// `TailscreenProtocol` where Linux CI tests them. This type is delivery, and
/// knows nothing about viewers or shares.
///
/// **Button presses do not arrive here.** They come back through
/// `Microsoft.Windows.AppLifecycle`'s `ExtendedActivationKind.AppNotification`,
/// which swift-winui projects in Swift — the host reads the activation argument
/// string and passes it to `decodeAction(fromActivationArguments:)`. That is
/// why this class has no `onAction`, and why the shim under it has no COM
/// handler.
public final class WindowsNotifier: @unchecked Sendable {
    /// `AppNotificationSetting` — whether a posted toast will be seen.
    ///
    /// The Windows answer to macOS's `getNotificationSettings` and Linux's
    /// `GetCapabilities`, and it fails in the same quiet way: posting still
    /// *succeeds* when the user has turned notifications off. A host that does
    /// not read this is a host whose approval prompts silently stop arriving,
    /// with no error anywhere.
    public enum Setting: Int32, Sendable, CaseIterable {
        case enabled = 0
        case disabledForApplication = 1
        case disabledForUser = 2
        case disabledByGroupPolicy = 3
        case disabledByManifest = 4
        case unsupported = 5
        /// The query failed, or this is not Windows. Distinct from
        /// `unsupported`, which is the platform's own answer.
        case unknown = 6
    }

    /// A button. `key` comes back verbatim in the activation arguments.
    public typealias Button = WindowsToastPayload.Button

    private let handle: OpaquePointer?

    /// Test seam: when set, `post` composes everything as usual and hands the
    /// result here instead of to the platform. There is no notification
    /// platform off Windows and nothing stands in for one, so this is how the
    /// composition — payload, tag, priority, group — is exercised on Linux CI.
    var deliverForTesting: ((_ payload: String, _ tag: String, _ group: String, _ highPriority: Bool) -> UInt32)?
    /// Test seam: what `withdraw` was asked to remove.
    var withdrawnForTesting: ((_ tag: String?, _ group: String) -> Void)?

    /// Whether this desktop understands `scenario="urgent"`.
    ///
    /// Read once at open. It is a Windows 11 attribute, and an unrecognized
    /// scenario is a schema violation rather than an ignored hint — the payload
    /// is rejected and nothing is posted at all. `WindowsToastPayload.scenario`
    /// takes this and downgrades to `reminder`, which every build understands.
    public let supportsUrgentScenario: Bool

    /// Whether this build has a notification platform at all — false off
    /// Windows.
    public static var isSupported: Bool { ts_winnotify_is_supported() != 0 }

    /// Register with the notification platform, or return nil when there is
    /// nowhere to post.
    ///
    /// **Nil is a normal state**, exactly as it is for `DesktopNotifier.init?`
    /// on a box with no notification daemon. `AppNotificationManager` needs a
    /// Windows App Runtime the process can reach, and the zip build ships a
    /// self-contained runtime whose Singleton package — the one the
    /// notification APIs need — is deliberately not staged. So an unpackaged
    /// run can legitimately land here.
    ///
    /// That is the packaging fork settled at runtime instead of build time: one
    /// code path, no flag, and the host degrades to its in-window prompts and
    /// says so on the share card. `openError` is for the log, not for an alert.
    ///
    /// - Parameter displayName: the name a toast is attributed to, for the
    ///   unpackaged case where there is no manifest carrying one. Nil takes the
    ///   no-argument `Register()` the packaged case wants anyway.
    public init?(displayName: String? = "Tailscreen") {
        guard let handle = ts_winnotify_open(displayName) else { return nil }
        self.handle = handle
        supportsUrgentScenario = ts_winnotify_supports_urgent() != 0
    }

    /// Test-only: no registration, no platform. `deliverForTesting` receives
    /// what would have been posted.
    init(testingWith supportsUrgentScenario: Bool) {
        handle = nil
        self.supportsUrgentScenario = supportsUrgentScenario
    }

    deinit {
        // Synchronous only, and it unregisters before releasing: the
        // registration installs a COM activator naming this executable, and one
        // left behind outlives the process.
        if let handle { ts_winnotify_close(handle) }
    }

    /// Why `init?` returned nil, for the log.
    public static var openError: String? {
        ts_winnotify_open_error().map(String.init(cString:))
    }

    /// Whether a toast posted right now would be seen.
    ///
    /// Re-read on every access rather than cached at open: a user can turn
    /// notifications off in the middle of a share, which is the moment it
    /// matters most.
    public var setting: Setting {
        guard let handle else { return .unknown }
        return Setting(rawValue: ts_winnotify_setting(handle)) ?? .unknown
    }

    /// The one-line version, for the share card's "approvals appear here only".
    public var canBeSeen: Bool { setting == .enabled }

    /// Post a notice, or replace the one already posted for the same identity.
    ///
    /// Returns the tag it was posted under — pass it to `withdraw` when the
    /// thing the notice is about ends. Nil when the platform refused it.
    ///
    /// Reposting for the same `identity` REPLACES the toast in place rather
    /// than stacking a second copy, because the tag is a pure function of the
    /// identity. That is the Windows spelling of freedesktop's `replaces_id`.
    ///
    /// - Parameters:
    ///   - identity: the notice's dedupe key, from `SharerNotice.id`. It also
    ///     rides every button's activation string, so the host learns *who* a
    ///     press was about with no lookup table to go stale.
    ///   - blocksSomeone: `SharerNoticeKind.blocksSomeone` — somebody is stuck
    ///     inside a session that is already running. The only notices that
    ///     break through Focus Assist, because the exemption is revoked per
    ///     *app* and one over-eager kind disarms the rest.
    @discardableResult
    public func post(
        summary: String,
        body: String = "",
        buttons: [Button] = [],
        identity: String,
        blocksSomeone: Bool = false
    ) -> String? {
        let scenario = WindowsToastPayload.scenario(
            blocksSomeone: blocksSomeone,
            actionable: !buttons.isEmpty,
            supportsUrgent: supportsUrgentScenario)
        let payload = WindowsToastPayload.xml(
            summary: summary, body: body, buttons: buttons,
            scenario: scenario, identity: identity)
        let tag = WindowsToastPayload.tag(for: identity)
        let group = WindowsToastPayload.group

        if let deliverForTesting {
            return deliverForTesting(payload, tag, group, blocksSomeone) == 0 ? nil : tag
        }
        guard let handle else { return nil }
        // `high_priority` is AppNotificationPriority, which is about DELIVERY
        // (it survives battery saver) and is a different axis from the
        // payload's scenario, which is about display. Both are spent on the
        // same narrow set.
        let id = ts_winnotify_post(handle, payload, tag, group, blocksSomeone ? 1 : 0)
        return id == 0 ? nil : tag
    }

    /// Take a notice back off the screen.
    ///
    /// Part of the API rather than left to expiry, for the reason the Linux
    /// backend states: a banner reading "someone is waiting to be let in", with
    /// an Accept button, is actively wrong once they have been admitted from
    /// the app window — pressing it then does nothing, or lands on whoever
    /// connects next.
    public func withdraw(_ tag: String) {
        if let withdrawnForTesting {
            withdrawnForTesting(tag, WindowsToastPayload.group)
            return
        }
        guard let handle else { return }
        ts_winnotify_withdraw(handle, tag, WindowsToastPayload.group)
    }

    /// Clear every notice this app posted.
    ///
    /// What a share teardown calls: stopping a share expels every viewer at
    /// once, and a prompt left behind is one somebody can still press.
    public func withdrawAll() {
        if let withdrawnForTesting {
            withdrawnForTesting(nil, WindowsToastPayload.group)
            return
        }
        guard let handle else { return }
        ts_winnotify_withdraw_group(handle, WindowsToastPayload.group)
    }

    /// The last delivery failure, or nil.
    public var lastError: String? {
        guard let handle else { return nil }
        return ts_winnotify_last_error(handle).map(String.init(cString:))
    }

    /// Read a button press out of the activation arguments AppLifecycle hands
    /// the host.
    ///
    /// Returns nil for a launch that was not ours. Windows delivers activation
    /// arguments from whatever posted them, and answering a foreign launch as
    /// if a viewer were waiting on it is the failure worth refusing.
    public static func decodeAction(
        fromActivationArguments raw: String
    ) -> (action: String, identity: String)? {
        WindowsToastPayload.decodeArguments(raw)
    }
}
