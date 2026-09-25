import Foundation

/// Which microphone a single global mute hotkey flips.
///
/// The app can share and watch at once, each with its own mic and mute
/// latch (deliberate: one control flipping both would mute someone in a
/// call they aren't in). The in-window buttons keep them separate; the
/// hotkey can't, since there's only one chord.
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

/// The routing decision, and why it's a decision rather than a fan-out.
///
/// **Flipping both was rejected**: toggling two independent latches that
/// disagree has no coherent meaning, and "mute everything if anything is
/// live" just moves the mismatch to the second press.
///
/// **The sharer wins when both are live**, because while sharing the app
/// window (and its mic button) is necessarily behind whatever's being
/// demonstrated, whereas the viewer's video window — and its mic button —
/// is what's on screen. So the hotkey is a sharer affordance; the viewer
/// only gets it when no share is running.
///
/// Cost: starting a share mid-viewing-session silently retargets the chord.
/// Hosts must surface which mic it points at (``MuteHotkeyTarget/label``);
/// the per-session buttons stay the unambiguous control.
public enum MuteHotkeyRouting {
    /// The microphone the hotkey flips right now, or nil when there is none.
    /// "Available" means a live uplink, not merely a session — a share with
    /// no working capture device must not shadow the viewer's mic.
    public static func target(
        sharerMicAvailable: Bool, viewerMicAvailable: Bool
    ) -> MuteHotkeyTarget? {
        if sharerMicAvailable { return .sharer }
        if viewerMicAvailable { return .viewer }
        return nil
    }

    /// Whether the hotkey should be held at all. A global grab is exclusive
    /// and takes the chord from every other app, so registration follows the
    /// target: something to mute, grab it; nothing, let it go.
    public static func shouldRegister(
        sharerMicAvailable: Bool, viewerMicAvailable: Bool
    ) -> Bool {
        target(sharerMicAvailable: sharerMicAvailable, viewerMicAvailable: viewerMicAvailable)
            != nil
    }
}
