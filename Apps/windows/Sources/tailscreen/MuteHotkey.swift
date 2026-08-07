import Foundation
import TailscreenProtocol
import WinHotkeyKit

/// The Windows half of the mute hotkey: one call to `RegisterHotKey` through
/// the shim, and nothing else.
///
/// The controller around it — when to hold, when to let go, what a press
/// flips, what is said and how often — is `PortableMuteHotkey` in
/// TailscreenProtocol, shared with the GTK app and tested on Linux CI.
///
/// Deliberately shorter than its X11 sibling, and both differences are the
/// platform's. There is no session-type pre-flight (nothing here is XWayland),
/// and no repeat latch — `MOD_NOREPEAT` rides every registration
/// `WindowsHotkeyMapping` emits, so a held chord is already one activation.
/// What is NOT shorter is the cost of re-taking the chord: it destroys and
/// recreates the shim's pump thread, which is why the controller only acts on
/// the hold/release decision when it changes.
struct WindowsMuteHotkeyBinding: GlobalHotkeyBinding {
    func hold(
        _ chord: ShortcutChord
    ) -> Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability> {
        WindowsHotkey.hold(chord).map { $0 as any GlobalHotkeyHolding }
    }
}

/// The WinUI app's mute-hotkey controller: the shared one, over the Windows
/// binding.
@MainActor
func makeMuteHotkeyController(
    sharerMicAvailable: @escaping @MainActor () -> Bool,
    viewerMicAvailable: @escaping @MainActor () -> Bool,
    toggleSharerMic: @escaping @MainActor () -> Void,
    toggleViewerMic: @escaping @MainActor () -> Void
) -> PortableMuteHotkey? {
    PortableMuteHotkey(
        binding: WindowsMuteHotkeyBinding(),
        sharerMicAvailable: sharerMicAvailable,
        viewerMicAvailable: viewerMicAvailable,
        toggleSharerMic: toggleSharerMic,
        toggleViewerMic: toggleViewerMic,
        // stdout, which `ConsoleBridge` routes to wherever this build's console
        // goes.
        note: { print($0) })
}
