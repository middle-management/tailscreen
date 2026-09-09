/// Whether the hub's share card may offer to start a share, and why not when
/// it may not.
///
/// The GTK and WinUI hubs are one window: the share card sits above the screen
/// list in every phase, including before the tsnet node exists. Both used to
/// offer Share there anyway, and both failed differently for it — the GTK app
/// reached `beginShare`, found no node and reported "Share failed: Tailscale
/// isn't up yet"; the WinUI app's `startSharing` guarded on `phase == .ready`
/// and so did *nothing at all*, which is the worse of the two because a button
/// that silently does nothing reads as a broken app rather than a wrong moment.
///
/// The rule is the one `canShareWindow` already states for the capture
/// backend: never offer a share the start path will refuse. This is the same
/// rule applied to the other precondition, so the two cannot disagree.
public enum HubShareAvailability: Equatable, Sendable, CaseIterable {
    /// Both preconditions hold — offer the button.
    case available
    /// This machine has no capture backend at all (no portal on Wayland, no
    /// display on X11). Permanent for the session; the card says so through
    /// the backend's own `unavailableReason`, which is more specific than
    /// anything this type could word.
    case captureUnavailable
    /// There is no node yet, so there is nothing to share *over*. Unlike the
    /// case above this clears itself — the hub is either bringing the node up
    /// or waiting for a browser sign-in, and the card's own status line says
    /// which.
    case waitingForNode

    /// `captureUnavailable` outranks `waitingForNode`, and the order is the
    /// whole content of this function: a machine that can never share must not
    /// be told to wait for a node, because waiting is advice that implies the
    /// button will appear, and on that machine it never will.
    public static func decide(captureAvailable: Bool, nodeIsUp: Bool) -> HubShareAvailability {
        if !captureAvailable { return .captureUnavailable }
        if !nodeIsUp { return .waitingForNode }
        return .available
    }

    /// The one thing the card asks of this type.
    public var canStartShare: Bool { self == .available }
}
