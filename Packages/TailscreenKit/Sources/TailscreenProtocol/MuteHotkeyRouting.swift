import Foundation

/// Which microphone a single global mute hotkey flips.
///
/// These apps can **share and watch at once**, and the two directions carry
/// separate microphones with separate mute latches — deliberately, because one
/// control flipping both would mute somebody in a call they are not in. That
/// is settled for the in-window buttons (`toggleMic` vs `toggleShareMic`); a
/// hotkey has no such luxury, because there is exactly one chord.
public enum MuteHotkeyTarget: String, Equatable, Sendable, CaseIterable {
    case sharer
    case viewer

    /// English source text naming the target, for the tooltip/caption that
    /// tells the user which microphone the chord is currently pointed at.
    /// Hosts localize.
    public var label: String {
        switch self {
        case .sharer: "your microphone in the screen you are sharing"
        case .viewer: "your microphone in the screen you are watching"
        }
    }
}

/// The routing decision, and the reason it is a decision rather than a fan-out.
///
/// **Flipping both was rejected.** A toggle over two independent latches has no
/// coherent meaning when they disagree: with the share muted and the viewing
/// session live, one press produces the exact inverse mismatch. Re-defining it
/// as "if anything is live, mute everything" fixes the mute direction and
/// breaks the other one — the second press unmutes you into a call you were
/// only listening to, which is the failure the two-button split exists to
/// prevent.
///
/// **The sharer wins when both are live**, and the argument is the row this
/// closes: *mute from outside the window*. Being outside the window is not
/// symmetric between the two roles.
///
/// - While sharing you are necessarily in some *other* app — that is what you
///   are showing — so the app window, and the mic button on it, is behind
///   whatever you are demonstrating. This is the case that has no other answer.
/// - While watching, the video window is the thing you are looking at. The mic
///   button is on screen, an inch from the pointer.
///
/// So the hotkey is fundamentally a sharer affordance, and the viewer gets it
/// only because there is no reason to withhold it when no share is running.
///
/// The cost is honest and worth naming: start a share while already in a
/// viewing session and the chord silently changes which microphone it points
/// at. Hosts are expected to say which one it is (see ``MuteHotkeyTarget/label``)
/// rather than leave that invisible, and the per-session buttons remain the
/// unambiguous control.
public enum MuteHotkeyRouting {
    /// The microphone the hotkey flips right now, or nil when there is none.
    ///
    /// "Available" means a live microphone the user could mute — an attached
    /// uplink, not merely a session. A share with no working capture device
    /// must not shadow the viewer's mic, or a machine with a broken sharer
    /// microphone would answer every press with nothing at all.
    public static func target(
        sharerMicAvailable: Bool, viewerMicAvailable: Bool
    ) -> MuteHotkeyTarget? {
        if sharerMicAvailable { return .sharer }
        if viewerMicAvailable { return .viewer }
        return nil
    }

    /// Whether the hotkey should be held at all.
    ///
    /// A global grab is exclusive: whoever registers a chord takes it from
    /// every other app on the machine. Holding one while there is no
    /// microphone to mute is taking it for a handler with nothing to do — the
    /// same reason macOS registers its remote-control panic key only while a
    /// grant is live. So registration follows the target: something to mute,
    /// grab it; nothing, let it go.
    public static func shouldRegister(
        sharerMicAvailable: Bool, viewerMicAvailable: Bool
    ) -> Bool {
        target(sharerMicAvailable: sharerMicAvailable, viewerMicAvailable: viewerMicAvailable)
            != nil
    }
}
