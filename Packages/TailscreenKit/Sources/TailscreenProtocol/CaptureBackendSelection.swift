import Foundation

/// Which capture backend a Linux share should use, and why.
///
/// Two backends, not interchangeable. X11 root capture is instant and silent
/// but only ever sees the whole X server root window. The ScreenCast portal
/// can see a native Wayland desktop, a window or an app, but every share
/// begins with a consent dialog.
///
/// The choice is not "Wayland → portal": the portal is the better path on X11
/// too (only it can share one window), and X11 capture on a Wayland session
/// is actively misleading (see below), not merely worse. So the input is what
/// the person wants to share, not just what session they're running.
public enum CaptureBackendSelection {

    /// What kind of session this is. `unknown` is a real answer, not a
    /// placeholder — `XDG_SESSION_TYPE` is simply absent under `startx`, in a
    /// container, or over SSH with X forwarding.
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

    /// Inputs, grouped as one description of a machine rather than passed
    /// separately.
    public struct Environment: Sendable, Equatable {
        public let session: SessionKind
        /// `$DISPLAY`, or nil/empty when there is no X server to talk to.
        /// Set on Wayland too, by XWayland — why it can't be the only input.
        public let x11Display: String?
        /// Whether a ScreenCast portal answered, from a capability check that
        /// puts nothing on screen (`PortalSession.connect()`) — never a
        /// negotiation that raises a consent dialog.
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

    /// Read the session kind. `XDG_SESSION_TYPE` first; `WAYLAND_DISPLAY` as
    /// fallback. `DISPLAY` is deliberately not consulted — it's set under
    /// XWayland, and reading it as "this is X11" is the bug this type prevents.
    public static func sessionKind(fromEnvironment environment: [String: String]) -> SessionKind {
        switch environment["XDG_SESSION_TYPE"]?.lowercased() {
        case "wayland": return .wayland
        case "x11": return .x11
        default: break
        }
        if let wayland = environment["WAYLAND_DISPLAY"], !wayland.isEmpty { return .wayland }
        return .unknown
    }

    /// Pick a backend. Rules, each pinned by `CaptureBackendSelectionTests`:
    ///
    ///   * A window or app share is the portal or nothing — widening it to
    ///     the whole screen would be a privacy failure, not a missing feature.
    ///   * A Wayland session never gets X11 capture even though `$DISPLAY` is
    ///     set (XWayland sets it) — capturing the XWayland root shows a blank
    ///     or fragmentary screen with nothing erroring, which is what the
    ///     Linux app shipped before this existed.
    ///   * An X11 session sharing the whole screen keeps X11 capture — both
    ///     backends can serve it, and the portal would add an unasked-for
    ///     consent dialog.
    ///   * `unknown` is treated as X11 when there is a display to use
    ///     (`startx`, containers, forwarded SSH all genuinely are X11).
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
                    // Does not fall back to X11 even with `$DISPLAY` set — see the doc comment.
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

    /// Whether this environment can share anything at all — the value a
    /// hub's share button is enabled from. Derived from `choose`, not
    /// reimplemented, so the two can never disagree.
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
