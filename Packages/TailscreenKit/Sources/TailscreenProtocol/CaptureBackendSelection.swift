import Foundation

/// Which capture backend a Linux share should use, and why.
///
/// Two backends exist and they are not interchangeable. X11 root capture is
/// instant and silent — no dialog, no consent, nothing on screen — but it can
/// only ever see an X server, and only ever the whole root window. The
/// ScreenCast portal can see a native Wayland desktop, a single window and a
/// single application, but every share begins with a dialog the compositor
/// draws and a person clicks.
///
/// **The choice is not "Wayland → portal."** That framing is wrong in both
/// directions: the portal is the better path on an X11 session too, because it
/// is the only one that can share one window; and X11 capture on a *Wayland*
/// session is not merely worse, it is actively misleading — see below.
///
/// So the input is what the person is trying to share, not just what session
/// they happen to be running.
public enum CaptureBackendSelection {

    /// What kind of session this is.
    ///
    /// `unknown` is a real answer, not a placeholder: `XDG_SESSION_TYPE` is set
    /// by the login manager and is simply absent under `startx`, in a
    /// container, or over plain SSH with X forwarding. Treating absence as
    /// "not X11" would break the sessions most likely to be running this
    /// headlessly.
    public enum SessionKind: String, Sendable, Equatable, CaseIterable {
        case x11
        case wayland
        case unknown
    }

    /// What the person asked to share.
    public enum Intent: Sendable, Equatable, CaseIterable {
        /// The whole screen. Both backends can do this.
        case entireScreen
        /// One window, or one application. **Only the portal can do this** —
        /// there is no X11 path to it that respects the compositor.
        case windowOrApp
    }

    /// The answer.
    public enum Choice: Sendable, Equatable {
        /// Capture the X11 root of this display.
        case x11(display: String)
        /// Go through the ScreenCast portal. **Raises a consent dialog.**
        case portal
        /// Neither backend can serve this request; the string is for the
        /// sharer to read.
        case unavailable(String)
    }

    /// Inputs, grouped because there are four of them and swiftlint caps a
    /// function at five parameters — but mostly because they are one
    /// description of a machine, and passing them separately invites a caller
    /// to answer one of them from somewhere else.
    public struct Environment: Sendable, Equatable {
        public let session: SessionKind
        /// `$DISPLAY`, or nil/empty when there is no X server to talk to.
        ///
        /// **Set on Wayland too**, by XWayland, which is exactly why it cannot
        /// be the only input — see `choose`.
        public let x11Display: String?
        /// Whether a ScreenCast portal answered. This must come from a
        /// capability check that puts **nothing** on screen
        /// (`PortalSession.connect()`), never from a negotiation: a check that
        /// raises a consent dialog is not a check.
        public let portalAvailable: Bool

        public init(session: SessionKind, x11Display: String?, portalAvailable: Bool) {
            self.session = session
            self.x11Display = x11Display
            self.portalAvailable = portalAvailable
        }

        /// The display, or nil when it is absent OR empty. `DISPLAY=""` is
        /// common in service units and means the same thing as unset, but
        /// compares differently.
        var usableDisplay: String? {
            guard let x11Display, !x11Display.isEmpty else { return nil }
            return x11Display
        }
    }

    /// Read the session kind the way a desktop actually reports it.
    ///
    /// `XDG_SESSION_TYPE` first because it is the one the login manager sets
    /// deliberately; `WAYLAND_DISPLAY` as the fallback, since a Wayland
    /// compositor exports it even when nothing set the session type. `DISPLAY`
    /// is deliberately NOT consulted here — it is set under XWayland, so
    /// reading it as "this is X11" is the whole bug this type exists to
    /// prevent.
    public static func sessionKind(fromEnvironment environment: [String: String]) -> SessionKind {
        switch environment["XDG_SESSION_TYPE"]?.lowercased() {
        case "wayland": return .wayland
        case "x11": return .x11
        default: break
        }
        if let wayland = environment["WAYLAND_DISPLAY"], !wayland.isEmpty { return .wayland }
        return .unknown
    }

    /// Pick a backend.
    ///
    /// The rules, each pinned by `CaptureBackendSelectionTests`:
    ///
    ///   * **A window or app share is the portal or nothing.** X11 root capture
    ///     cannot scope to a window, and quietly widening the request to the
    ///     whole screen would be a privacy failure rather than a missing
    ///     feature — the same rule `X11CaptureEncoder` and `WGCCaptureEncoder`
    ///     already follow when they reject a selection kind they cannot serve.
    ///
    ///   * **A Wayland session never gets X11 capture, even though `$DISPLAY`
    ///     is set.** XWayland sets it, so the obvious check passes and the
    ///     share succeeds — capturing the XWayland root, which holds only the
    ///     X11 apps that happen to be running and on many desktops is empty or
    ///     a fragment. The sharer sees "Sharing"; viewers see a blank screen
    ///     or somebody's one legacy app. Nothing errors. That is the failure
    ///     this whole type is worth having for, and it is what the Linux app
    ///     shipped before this existed.
    ///
    ///   * **An X11 session sharing the whole screen keeps X11 capture.** Both
    ///     backends can serve it, and the portal would add a consent dialog to
    ///     every single share for no capability the person asked for. The
    ///     portal is *reachable* there — that is what `.windowOrApp` is for —
    ///     but it is not imposed.
    ///
    ///   * **`unknown` is treated as X11 when there is a display to use.**
    ///     `startx`, containers and forwarded SSH sessions all land here and
    ///     all genuinely are X11.
    public static func choose(intent: Intent, environment: Environment) -> Choice {
        switch intent {
        case .windowOrApp:
            guard environment.portalAvailable else {
                return .unavailable(
                    "sharing a single window or app needs a desktop portal, "
                        + "and this session has none")
            }
            return .portal

        case .entireScreen:
            switch environment.session {
            case .wayland:
                guard environment.portalAvailable else {
                    // Deliberately does NOT fall back to X11 even when
                    // `$DISPLAY` is set. See the doc comment: that fallback is
                    // a share that looks like it worked.
                    return .unavailable(
                        "this is a Wayland session and it has no desktop portal, "
                            + "so there is no way to capture the screen")
                }
                return .portal

            case .x11, .unknown:
                if let display = environment.usableDisplay {
                    return .x11(display: display)
                }
                if environment.portalAvailable {
                    return .portal
                }
                return .unavailable(
                    "no X display and no desktop portal, so there is nothing to capture")
            }
        }
    }

    /// Whether this environment can share anything at all — the value a hub's
    /// share button is enabled from.
    ///
    /// Derived from `choose` rather than reimplemented, so the button and the
    /// share can never disagree about whether this machine can share.
    public static func canShareAnything(environment: Environment) -> Bool {
        for intent in Intent.allCases {
            if case .unavailable = choose(intent: intent, environment: environment) { continue }
            return true
        }
        return false
    }

    /// Why sharing is unavailable, or nil when it is available. For the hub's
    /// status line.
    public static func unavailableReason(environment: Environment) -> String? {
        guard !canShareAnything(environment: environment) else { return nil }
        guard case .unavailable(let reason) = choose(intent: .entireScreen, environment: environment)
        else { return nil }
        return reason
    }
}
