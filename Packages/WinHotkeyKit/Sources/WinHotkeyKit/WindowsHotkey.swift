import CWinHotkey
import Foundation
import TailscreenProtocol

/// A system-wide hotkey held with `RegisterHotKey`. Windows sibling of
/// `X11Hotkey`, deliberately the same surface — hold a chord, drain
/// activations — so the two apps' controllers differ only in which type
/// they construct.
///
/// The shim owns a thread with a message pump (`WM_HOTKEY` is a thread
/// message XAML's pump would eat), and needs no repeat latch since
/// `MOD_NOREPEAT` is in every registration `WindowsHotkeyMapping` emits.
public final class WindowsHotkey {
    private var handle: UnsafeMutableRawPointer?

    /// Test seam: when set, `drain()` reads from this instead of the pump.
    var takeForTesting: (() -> Int)?

    /// Whether this build has `RegisterHotKey` at all.
    public static var isSupported: Bool { ts_winhotkey_supported() != 0 }

    /// Take `chord` system-wide, or say why not. `.alreadyOwned`: another
    /// application already holds the combo (`ERROR_HOTKEY_ALREADY_REGISTERED`).
    public static func hold(
        _ chord: ShortcutChord
    ) -> Result<
        WindowsHotkey, GlobalHotkeyUnavailability
    > {
        guard isSupported else { return .failure(.unsupportedPlatform) }
        guard let registration = WindowsHotkeyMapping.registration(for: chord) else {
            return .failure(.unmappableChord)
        }
        guard
            let handle = ts_winhotkey_create(registration.modifiers, registration.virtualKey)
        else {
            return .failure(.alreadyOwned)
        }
        return .success(WindowsHotkey(handle: handle))
    }

    private init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    /// Test-only: no registration, `takeForTesting` supplies activations.
    init(testingWith take: @escaping () -> Int) {
        handle = nil
        takeForTesting = take
    }

    deinit {
        if let handle { ts_winhotkey_destroy(handle) }
    }

    /// Give the chord back to the rest of the desktop. Explicit rather than
    /// left to `deinit` — "stop holding this" has to mean now.
    public func release() {
        if let handle { ts_winhotkey_destroy(handle) }
        handle = nil
    }

    /// How many times the chord was pressed since the last call.
    public func drain() -> Int {
        if let takeForTesting { return takeForTesting() }
        guard let handle else { return 0 }
        return Int(ts_winhotkey_take(handle))
    }
}

/// `drain()`/`release()` already match the portable controller's shape.
/// Declared here, not in the app, so neither host needs a `@retroactive` conformance.
extension WindowsHotkey: GlobalHotkeyHolding {}
