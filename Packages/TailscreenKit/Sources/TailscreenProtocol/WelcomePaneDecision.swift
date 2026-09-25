import Foundation

/// What the signed-out welcome pane offers, as pure functions of the flags
/// that drive it.
///
/// The pane itself is one card per way in — the tailnet and a share link —
/// since they aren't variants of each other; this states the one branch
/// inside that layout that's a decision rather than rendering.
///
/// Portable so the GTK and WinUI hubs (via `TailscreenHubUI`) and macOS (via
/// `AppState.welcomeLinkShareAction`) all read one pinned branch instead of
/// three copies that could quietly drift.
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

    /// The card's three-way branch. `canShare` is the host's own answer to
    /// "could I start a link share right now" (capture backend availability,
    /// idle window, Settings switch — the branch doesn't care which).
    /// `isIdle` is no share running or starting; `isLinkOnlyShare` is that
    /// the running one was started signed out.
    ///
    /// **Idle is answered first**, whatever the link flag says: a stale
    /// `isLinkOnlyShare` between one teardown write and the next must not
    /// claim a share that's being torn down. But a link-only share genuinely
    /// running on a host whose capture backend has since gone still renders
    /// the note — a share the person can't see the link for is one they
    /// can't end from the surface they're looking at.
    ///
    /// Both wrong answers are silent, so this is pinned rather than an
    /// inline ternary: an offered button on a host that can't capture walks
    /// someone into a refusal; a dropped note strands a running share.
    public static func linkShareAction(
        canShare: Bool,
        isIdle: Bool,
        isLinkOnlyShare: Bool
    ) -> LinkShareAction {
        if isIdle { return canShare ? .offer : .unavailable }
        if isLinkOnlyShare { return .sharingViaLink }
        return .unavailable
    }
}
