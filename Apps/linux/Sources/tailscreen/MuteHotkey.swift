import Foundation
import TailscreenProtocol
import X11HotkeyKit

/// The X11 half of the mute hotkey: everything about taking the chord that is
/// this platform's, and nothing else.
///
/// The controller around it — when to hold, when to let go, what a press
/// flips, what is said and how often — is `PortableMuteHotkey` in
/// TailscreenProtocol, shared with the WinUI app and tested on Linux CI.
///
/// Two things here are genuinely X11's:
///
///   * **The environment decision comes first**, and is re-taken on each
///     acquisition rather than cached. `$DISPLAY` is set on Wayland — XWayland
///     sets it — so a "do we have a display?" gate passes there and the grab
///     then silently under-delivers; `X11HotkeySupport` is the same
///     session-type-first rule `CaptureBackendSelection` uses. Re-taken because
///     a session type can only really change across a login, but caching a "no"
///     would also cache a transient failure to open the display.
///   * **Detectable auto-repeat**, which the Windows side gets for free from
///     `MOD_NOREPEAT`. Not fatal — losing the shortcut entirely is the worse
///     trade for a case that only arises while somebody leans on a key — but a
///     held chord may flutter the mute, so it is said once.
struct X11MuteHotkeyBinding: GlobalHotkeyBinding {
    /// Where the auto-repeat warning goes. Passed in rather than written here
    /// so this file has one console convention and the controller has the same
    /// one.
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

/// The GTK app's mute-hotkey controller: the shared one, over the X11 binding.
///
/// A factory rather than a subclass because `PortableMuteHotkey` is final and
/// has nothing left for a host to override — the whole of this app's part is
/// the binding above and the stderr convention below.
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
