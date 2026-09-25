import CWinNotify
import Foundation
import TailscreenProtocol

/// Desktop notifications on Windows, via the Windows App SDK's
/// `AppNotificationManager`. Sibling of `GNotifyKit.DesktopNotifier` on
/// Linux and `UNUserNotificationCenter` on macOS, with deliberately the same
/// surface: construct, ask what the desktop can do, post, withdraw.
///
/// It exists because during a share the app window is behind the shared
/// content, so raising it is itself visible to viewers — an unattended
/// sharer would otherwise strand whoever tries to connect.
///
/// What to say and when is `SharerNoticeDecision`'s; words are
/// `SharerNoticeText`'s; XML is `WindowsToastPayload`'s — all tested on
/// Linux CI. This type is delivery only, knows nothing about viewers or shares.
///
/// **Button presses do not arrive here.** They come back through
/// `Microsoft.Windows.AppLifecycle`'s `ExtendedActivationKind.AppNotification`,
/// which swift-winui projects in Swift — the host reads the activation argument
/// string and passes it to `decodeAction(fromActivationArguments:)`. That is
/// why this class has no `onAction`, and why the shim under it has no COM
/// handler.
public final class WindowsNotifier: @unchecked Sendable {
    /// `AppNotificationSetting` — whether a posted toast will be seen.
    /// Posting still *succeeds* when the user has turned notifications off,
    /// so a host that doesn't read this has approval prompts silently stop
    /// arriving, with no error anywhere.
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
    /// result here instead of to the platform, exercising the composition on Linux CI.
    var deliverForTesting: ((_ payload: String, _ tag: String, _ group: String, _ highPriority: Bool) -> UInt32)?
    /// Test seam: what `withdraw` was asked to remove.
    var withdrawnForTesting: ((_ tag: String?, _ group: String) -> Void)?

    /// Whether this desktop understands `scenario="urgent"`. Read once at
    /// open — a Windows 11 attribute; an unrecognized scenario is a schema
    /// violation, not an ignored hint, so nothing posts at all.
    /// `WindowsToastPayload.scenario` downgrades to `reminder` accordingly.
    public let supportsUrgentScenario: Bool

    /// Whether this build has a notification platform at all — false off
    /// Windows.
    public static var isSupported: Bool { ts_winnotify_is_supported() != 0 }

    /// Register with the notification platform, or return nil when there is
    /// nowhere to post.
    ///
    /// **Nil is a normal state**, as with `DesktopNotifier.init?` on a box
    /// with no notification daemon: the zip build's self-contained runtime
    /// deliberately omits the Singleton package the notification APIs need,
    /// so an unpackaged run legitimately lands here and the host degrades to
    /// its in-window prompts. `openError` is for the log, not an alert.
    ///
    /// - Parameter displayName: the name a toast is attributed to, for the
    ///   unpackaged case with no manifest. Nil takes the packaged case's
    ///   no-argument `Register()`.
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
        // Unregisters before releasing — the registration installs a COM
        // activator naming this executable, which would otherwise outlive the process.
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

    /// Post a notice, or replace the one already posted for the same
    /// identity. Returns the tag posted under — pass to `withdraw` when the
    /// notice's subject ends; nil if the platform refused it.
    ///
    /// Reposting for the same `identity` REPLACES the toast in place (the
    /// tag is a pure function of identity) — the Windows spelling of
    /// freedesktop's `replaces_id`.
    ///
    /// - Parameters:
    ///   - identity: the notice's dedupe key, from `SharerNotice.id`. Also
    ///     rides every button's activation string, so the host learns who a
    ///     press was about with no lookup table.
    ///   - blocksSomeone: the only notices that break through Focus Assist
    ///     — the exemption is revoked per app, and one over-eager kind
    ///     disarms the rest.
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

    /// Take a notice back off the screen — a banner reading "someone is
    /// waiting to be let in" is actively wrong once admitted elsewhere.
    public func withdraw(_ tag: String) {
        if let withdrawnForTesting {
            withdrawnForTesting(tag, WindowsToastPayload.group)
            return
        }
        guard let handle else { return }
        ts_winnotify_withdraw(handle, tag, WindowsToastPayload.group)
    }

    /// Clear every notice this app posted — called on share teardown, since
    /// a prompt left behind is one somebody can still press.
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

    /// Read a button press out of the activation arguments AppLifecycle
    /// hands the host. Returns nil for a launch that wasn't ours.
    public static func decodeAction(
        fromActivationArguments raw: String
    ) -> (action: String, identity: String)? {
        WindowsToastPayload.decodeArguments(raw)
    }

    /// The same thing, starting from the `AppActivationArguments.data` object
    /// swift-winui hands the host — an `AppNotificationActivatedEventArgs`
    /// from the one namespace swift-winui doesn't project, arriving as an
    /// untyped `IInspectable` only a `QueryInterface` in the shim can read.
    ///
    /// - Parameter pointer: the raw `IInspectable*`, from
    ///   `IUnknown.pUnk.borrow`. Borrowed, never released.
    /// - Returns: nil for any other activation kind — the ordinary case, since
    ///   the host asks this of every activation it's woken by.
    public static func decodeAction(
        fromActivationData pointer: UnsafeMutableRawPointer
    ) -> (action: String, identity: String)? {
        // 1 KiB is many times what the payload can produce (a kind + peer
        // address); bounded here rather than a two-call length protocol.
        var buffer = [CChar](repeating: 0, count: 1024)
        let ok = buffer.withUnsafeMutableBufferPointer { out in
            ts_winnotify_activation_argument(pointer, out.baseAddress, Int32(out.count))
        }
        guard ok != 0 else { return nil }
        return decodeAction(fromActivationArguments: String(cString: buffer))
    }
}
