import CGNotify
import Foundation

/// Desktop notifications on Linux, over `org.freedesktop.Notifications`.
///
/// The sharer surface that reaches somebody whose attention is on the thing
/// they are sharing. "Require approval for new viewers" defaults **on**, so an
/// unattended sharer strands whoever tries to connect — there is nothing on
/// screen to notice and the app window is behind the shared content, where
/// raising it is itself visible to viewers.
///
/// What to say and when is `SharerNoticeDecision` in `TailscreenProtocol`; this
/// is delivery only, and deliberately knows nothing about viewers or shares.
public final class DesktopNotifier: @unchecked Sendable {
    /// The freedesktop urgency hint.
    ///
    /// `critical` is the level that survives Do Not Disturb, and on most
    /// daemons also the level that never expires on its own. Spend it only
    /// where somebody is genuinely stuck: users revoke the exemption per
    /// *app*, so one over-eager kind disarms the rest.
    public enum Urgency: UInt8, Sendable {
        case low = 0
        case normal = 1
        case critical = 2
    }

    /// A button. `key` comes back verbatim in `onAction`.
    public struct Action: Sendable {
        public let key: String
        public let label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    /// Why a notification went away — the freedesktop reason code.
    public enum CloseReason: UInt32, Sendable {
        case expired = 1
        /// The user dismissed it. **Not** a decision about anything: swiping a
        /// banner away must never be read as "deny".
        case dismissed = 2
        /// `withdraw` closed it.
        case withdrawn = 3
        case undefined = 4
    }

    /// A button was pressed. Fires on the thread whose main context is being
    /// iterated — see `init`.
    public var onAction: ((UInt32, String) -> Void)?
    /// A notification went away, for any reason.
    public var onClose: ((UInt32, CloseReason) -> Void)?

    private let handle: OpaquePointer

    /// Whether the daemon will actually render buttons.
    ///
    /// Checked once, at open. A daemon that does not advertise `actions`
    /// silently DROPS them rather than failing the call, so posting an
    /// Accept/Deny pair to one produces a banner that states a decision and
    /// offers no way to make it. Callers must ask, and say where to answer
    /// instead.
    public let supportsActions: Bool
    /// Whether the daemon renders the body text at all. A few render only the
    /// summary, which turns a two-line notice into a headline with the useful
    /// half missing.
    public let supportsBody: Bool

    /// Connect, or return nil when there is nowhere to post.
    ///
    /// Nil is a normal state — a headless box, a minimal session, a container
    /// with no bus. The host keeps its in-window prompts and says nothing;
    /// `openError` is for the log, not for an alert.
    ///
    /// **Construct this on the thread whose `GMainContext` is iterated.** GDBus
    /// captures the thread-default context when it subscribes, so a notifier
    /// built on a thread that never runs a main loop posts perfectly and never
    /// reports a single button press. In the GTK app that is the main thread.
    public init?(appName: String = "Tailscreen", desktopEntry: String? = "tailscreen") {
        guard let handle = ts_gnotify_open(appName, desktopEntry) else { return nil }
        self.handle = handle
        supportsActions = ts_gnotify_has_capability(handle, "actions") != 0
        supportsBody = ts_gnotify_has_capability(handle, "body") != 0

        let context = Unmanaged.passUnretained(self).toOpaque()
        ts_gnotify_set_callbacks(
            handle,
            { id, key, ctx in
                guard let ctx else { return }
                let notifier = Unmanaged<DesktopNotifier>.fromOpaque(ctx).takeUnretainedValue()
                notifier.onAction?(id, key.map(String.init(cString:)) ?? "")
            },
            { id, reason, ctx in
                guard let ctx else { return }
                let notifier = Unmanaged<DesktopNotifier>.fromOpaque(ctx).takeUnretainedValue()
                notifier.onClose?(id, CloseReason(rawValue: reason) ?? .undefined)
            },
            context)
    }

    deinit {
        // Synchronous only, and it unsubscribes before dropping the connection
        // — a signal delivered into a freed handle is the one crash this type
        // could plausibly cause.
        ts_gnotify_close(handle)
    }

    /// Why `init?` returned nil, for the log.
    public static var openError: String? {
        ts_gnotify_open_error().map(String.init(cString:))
    }

    /// Post, or replace a previous notification in place.
    ///
    /// Returns the daemon's id, or nil on failure. Pass that id back as
    /// `replacing` to update the same banner rather than stacking a second one,
    /// and to `withdraw` when the thing it is about is over.
    ///
    /// - Parameter expiresAutomatically: false pins the banner until it is
    ///   answered or withdrawn. Right for anything actionable: an approval
    ///   prompt that times out silently leaves the person on the other end
    ///   waiting forever with nobody aware of it.
    @discardableResult
    public func post(
        summary: String,
        body: String = "",
        actions: [Action] = [],
        urgency: Urgency = .normal,
        replacing: UInt32 = 0,
        expiresAutomatically: Bool = true
    ) -> UInt32? {
        // Flattened to the alternating key,label array the wire wants, and
        // dropped entirely when the daemon cannot render buttons — sending
        // them anyway would be invisible rather than harmless, since the
        // caller would then believe the notice was actionable.
        var flattened: [String] = []
        if supportsActions {
            for action in actions {
                flattened.append(action.key)
                flattened.append(action.label)
            }
        }

        let id = withCStringArray(flattened) { pointers -> UInt32 in
            ts_gnotify_post(
                handle, replacing, summary, body, pointers,
                urgency.rawValue, expiresAutomatically ? -1 : 0)
        }
        return id == 0 ? nil : id
    }

    /// Take a notification back off the screen.
    ///
    /// The reason this is part of the API rather than left to expiry: a banner
    /// reading "someone is waiting to be let in", with an Accept button, is
    /// actively wrong once they have been let in from the app window. A
    /// notice's life is tied to the thing it is about.
    public func withdraw(_ id: UInt32) {
        ts_gnotify_withdraw(handle, id)
    }

    /// The last delivery failure, or nil.
    public var lastError: String? {
        ts_gnotify_last_error(handle).map(String.init(cString:))
    }

    /// Hand `strings` to C as a NULL-terminated `char *[]`.
    ///
    /// Built by hand rather than with nested `withCString` closures because the
    /// count is not known at compile time, and the array must outlive every
    /// element — an element freed while the array still points at it is a
    /// use-after-free that shows up as a garbled button label rather than a
    /// crash.
    private func withCStringArray<T>(
        _ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> T
    ) -> T {
        guard !strings.isEmpty else { return body(nil) }
        let owned = strings.compactMap { strdup($0) }
        defer { owned.forEach { free($0) } }
        // A strdup that returned nil would silently shorten the array and pair
        // a key with the wrong label, so a partial copy is no copy at all.
        guard owned.count == strings.count else { return body(nil) }
        var pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        pointers.append(nil)
        return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
