import Foundation

/// Where the app's tailnet node is in its bring-up, as the hub presents it.
///
/// This is intentionally in the dependency-free protocol tier rather than in
/// any UI package or transport, for the same reason `ViewerSessionPhase` is:
/// macOS, GTK and WinUI all render one bring-up, and keeping a separate
/// enum per host gave them one chance each to disagree about it. They took
/// it. Before this type there were three vocabularies with no case in common
/// — the GTK picker's `signedOut / startingNode / discovering / picking /
/// connecting(String)`, the WinUI hub's `idle / starting / ready / failed`,
/// and the macOS hub's pair of Bools — describing the same five moments.
///
/// Two deliberate omissions, both of which were cases somewhere before:
///
/// * **There is no `connecting`.** Dialing a peer is the viewer session's
///   `ViewerSessionPhase.connecting`, and the GTK picker modelling it a
///   second time is what let two state machines hold two answers about one
///   moment: `sessionHost` had to read the picker's copy as a fallback for
///   the lifecycle's, because either could be the one that had landed. A host
///   that must suppress picker activity while a dial is in flight tracks that
///   beside this phase, not inside it.
/// * **There is no `switchingAccount`.** Every host tears the node down and
///   brings it back up under the new state directory, so the honest phase
///   during a switch is `startingNode`. The macOS hub's separate switching
///   pane is a presentation choice layered on that, not a sixth state.
///
/// `discovering` is the one case a host may legitimately never enter: the
/// WinUI hub goes straight from `startingNode` to `ready` and reports its peer
/// sweep through a separate refreshing flag. The case exists because the GTK
/// hub does distinguish it, and collapsing it into `ready` there would lose
/// the "Looking for screens…" placard that covers a genuinely slow first list.
public enum NodeBringUpPhase: Equatable, Sendable {
    /// No node, no login, nothing on the network — the welcome pane's state,
    /// and the state at a first launch. The two ways on from here that need no
    /// Tailscale account at all (join by link, share by link) live on that
    /// pane precisely because this phase is where somebody without an account
    /// stays.
    case signedOut
    /// Bringing the tsnet node up, possibly parked on a browser login.
    case startingNode
    /// The node is up and the first peer list is being built.
    case discovering
    /// Settled and signed in: the screens list is what the window shows.
    case ready
    /// Bring-up failed, carrying the reason as the person is told it.
    case failed(String)

    /// Whether the hub shows its welcome / sign-in pane.
    ///
    /// A failed bring-up belongs here: the way out of it is the same button,
    /// relabelled to retry. Both swift-cross-ui hubs already agreed on that
    /// before this type existed — GTK by returning to `signedOut` with a note
    /// beside it, WinUI by admitting `failed` to its own `isSignedOut` — and
    /// this is where those two spellings meet.
    public var isSignedOut: Bool {
        switch self {
        case .signedOut, .failed: true
        default: false
        }
    }

    /// Whether something is genuinely in flight, for the header spinner.
    ///
    /// Deliberately false for `failed`: a spinner that never stops makes a
    /// stopped app look like a working one, which is the one reading a
    /// progress indicator must never support.
    public var isBringingUp: Bool {
        switch self {
        case .startingNode, .discovering: true
        default: false
        }
    }

    /// The settled state that the list, the filter, Refresh and account
    /// switching are all gated on.
    public var isReady: Bool { self == .ready }

    /// Why bring-up failed, or nil.
    ///
    /// The sign-in pane prints this and swaps its button to a retry. Carrying
    /// the reason in the case is what lets a host drop the parallel note slot
    /// it used to keep beside the phase — two values that had to be written
    /// and cleared together, and therefore two values that could disagree.
    public var failureReason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }

    /// Whether this is the failed state, whatever the reason — the test that
    /// `== .failed` was before the reason rode along inside the case.
    public var hasFailed: Bool { failureReason != nil }
}
