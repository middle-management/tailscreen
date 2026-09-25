import Foundation
import TailscreenProtocol
import X11HotkeyKit

/// The X11 half of the mute hotkey. The controller — when to hold/release,
/// what a press flips, what's said and how often — is the shared
/// `PortableMuteHotkey` in TailscreenProtocol.
///
/// Two things here are genuinely X11's:
///
///   * **The environment decision comes first, re-taken on each acquisition
///     (not cached).** `$DISPLAY` is set under XWayland too, so a naive
///     "do we have a display?" gate would pass on Wayland and the grab would
///     silently under-deliver; `X11HotkeySupport` uses the same
///     session-type-first rule as `CaptureBackendSelection`. Not cached
///     because a transient display-open failure shouldn't stick as a
///     permanent "no".
///   * **Detectable auto-repeat**, which Windows gets for free from
///     `MOD_NOREPEAT`. Not fatal here, but a held chord may flutter the mute,
///     so it's warned about once.
struct X11MuteHotkeyBinding: GlobalHotkeyBinding {
    /// Passed in so this file and the controller share one console convention.
    let note: @Sendable (String) -> Void

    func hold(
        _ chord: ShortcutChord
    ) -> Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability> {
        if let reason = X11HotkeySupport.decideFromEnvironment() { return .failure(reason) }
        guard let candidate = X11Hotkey() else { return .failure(.noDisplay) }
        if let reason = candidate.grab(chord) { return .failure(reason) }
        if !candidate.honoursDetectableAutoRepeat {
            note(
                "warning: this X server has no detectable auto-repeat; "
                    + "holding \(chord.display(.words)) may flip the microphone repeatedly")
        }
        return .success(candidate)
    }
}

/// The GTK app's mute-hotkey controller: `PortableMuteHotkey` over the X11
/// binding. A factory, not a subclass, since `PortableMuteHotkey` is final.
@MainActor
func makeMuteHotkeyController(
    sharerMicAvailable: @escaping @MainActor () -> Bool,
    viewerMicAvailable: @escaping @MainActor () -> Bool,
    toggleSharerMic: @escaping @MainActor () -> Void,
    toggleViewerMic: @escaping @MainActor () -> Void
) -> PortableMuteHotkey? {
    // stderr, matching this app's other diagnostics — there is no TSLogger
    // convention on this side.
    let note: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    return PortableMuteHotkey(
        binding: X11MuteHotkeyBinding(note: note),
        sharerMicAvailable: sharerMicAvailable,
        viewerMicAvailable: viewerMicAvailable,
        toggleSharerMic: toggleSharerMic,
        toggleViewerMic: toggleViewerMic,
        note: note)
}
