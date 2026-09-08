import Foundation

/// What the signed-out welcome pane offers, as pure functions of the flags
/// that drive it.
///
/// The pane itself is one card per way in — the tailnet (sign in once, then
/// every Tailscreen shows up by name) and a share link (nothing to sign into,
/// both directions, guest approval mandatory) — because they are not variants
/// of each other. The macOS hub states that layout in SwiftUI and this states
/// the one branch inside it that is a decision rather than a rendering.
///
/// Portable because the GTK and WinUI hubs render the same pane out of
/// `TailscreenHubUI`, and because a branch with three outcomes and two silent
/// failure modes is worth pinning once rather than per host. (The macOS app
/// carries the same decision as `AppState.welcomeLinkShareAction`; converging
/// the two is rename-shaped follow-up work, not a design question.)
public enum WelcomePaneDecision {
    /// What the share-link card offers for the **sharing** half of the link
    /// feature. Its *joining* half is never gated — pasting a token is
    /// exactly the path that needs no account, no capture backend, and no
    /// settings, so it is always on screen.
    public enum LinkShareAction: Equatable, Sendable {
        /// Offer "Share your screen via Link…": the share comes up over the
        /// guest tunnel with its link as the only way in.
        case offer
        /// A link-only share is already running — say so, and point at where
        /// its link and guests are (the menu bar on macOS; the share card
        /// under this one on the hosts whose window is the only surface).
        case sharingViaLink
        /// Nothing to offer: this machine cannot capture anything, or a
        /// share is mid-bring-up and a second one would only fail the share
        /// lock.
        case unavailable
    }

    /// The card's three-way branch. `canShare` is the host's capture answer
    /// (a Wayland session with no portal cannot share at all), `isIdle` that
    /// no share is running or starting, `isLinkOnlyShare` that the one that
    /// *is* running was started signed out.
    ///
    /// The precedence matters and is not symmetric: `.offer` is checked
    /// first, so the ordinary signed-out-and-idle case never has to reason
    /// about `isLinkOnlyShare` (which is false then anyway). The case that
    /// would be wrong the other way round is a link-only share running on a
    /// host whose capture backend has since gone — the note still has to
    /// render, because a share the person cannot see the link for is a share
    /// they cannot end from the surface they are looking at.
    ///
    /// Both wrong answers are silent, which is why this is a pinned decision
    /// rather than an inline ternary: an offered button on a host that cannot
    /// capture walks somebody into a refusal, and a dropped note leaves a
    /// running share with nothing on screen saying where its link lives.
    public static func linkShareAction(
        canShare: Bool,
        isIdle: Bool,
        isLinkOnlyShare: Bool
    ) -> LinkShareAction {
        if canShare, isIdle { return .offer }
        if isLinkOnlyShare { return .sharingViaLink }
        return .unavailable
    }
}
