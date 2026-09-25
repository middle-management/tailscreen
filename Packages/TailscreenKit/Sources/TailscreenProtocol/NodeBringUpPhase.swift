import Foundation

/// Where the app's tailnet node is in its bring-up, as the hub presents it.
///
/// Dependency-free tier, like `ViewerSessionPhase`: macOS, GTK and WinUI all
/// render one bring-up from this shared enum instead of each keeping its own
/// vocabulary and risking disagreement.
///
/// Two deliberate omissions:
/// * **No `connecting`** — dialing a peer is `ViewerSessionPhase.connecting`;
///   a host suppressing picker activity mid-dial tracks that separately.
/// * **No `switchingAccount`** — every host tears the node down and brings
///   it back up under the new state dir, so the honest phase is
///   `startingNode`; a switching UI is a presentation choice on top.
///
/// `discovering` is the one case a host may legitimately never enter (WinUI
/// goes straight to `ready` and reports its peer sweep separately); GTK uses
/// it for its "Looking for screens…" placard.
public enum NodeBringUpPhase: Equatable, Sendable {
    /// No node, no login — the welcome pane's state, and first launch. Join-
    /// by-link and share-by-link live on that pane because this is where
    /// someone without a Tailscale account stays.
    case signedOut
    /// Bringing the tsnet node up, possibly parked on a browser login.
    case startingNode
    /// The node is up and the first peer list is being built.
    case discovering
    /// Settled and signed in: the screens list is what the window shows.
    case ready
    /// Bring-up failed, carrying the reason as the person is told it.
    case failed(String)

    /// Whether the hub shows its welcome / sign-in pane. A failed bring-up
    /// belongs here: the way out is the same button, relabelled to retry.
    public var isSignedOut: Bool {
        switch self {
        case .signedOut, .failed: true
        default: false
        }
    }

    /// Whether something is genuinely in flight, for the header spinner.
    /// False for `failed` — a spinner that never stops would make a stopped
    /// app look like a working one.
    public var isBringingUp: Bool {
        switch self {
        case .startingNode, .discovering: true
        default: false
        }
    }

    /// The settled state that the list, the filter, Refresh and account
    /// switching are all gated on.
    public var isReady: Bool { self == .ready }

    /// Why bring-up failed, or nil. The sign-in pane prints this and swaps
    /// its button to a retry.
    public var failureReason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }

    /// Whether this is the failed state, whatever the reason.
    public var hasFailed: Bool { failureReason != nil }
}
