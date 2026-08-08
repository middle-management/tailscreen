import CWinHotkey
import Foundation
import TailscreenProtocol

/// A system-wide hotkey held with `RegisterHotKey`.
///
/// The Windows sibling of `X11Hotkey`, with deliberately the same surface —
/// hold a chord, drain activations from the host's tick — so the two apps'
/// controllers differ only in which type they construct.
///
/// Two things genuinely differ underneath, and both are the platform's doing.
/// The shim owns a thread with a message pump (`WM_HOTKEY` is a thread message
/// and XAML's pump would eat it), and there is no repeat latch, because
/// `MOD_NOREPEAT` is part of every registration `WindowsHotkeyMapping` emits.
public final class WindowsHotkey {
    private var handle: UnsafeMutableRawPointer?

    /// Test seam: when set, `drain()` reads from this instead of the pump.
    var takeForTesting: (() -> Int)?

    /// Whether this build has `RegisterHotKey` at all.
    public static var isSupported: Bool { ts_winhotkey_supported() != 0 }

    /// Take `chord` system-wide, or say why not.
    ///
    /// The failure that matters is `.alreadyOwned`: `RegisterHotKey` returns
    /// FALSE with `ERROR_HOTKEY_ALREADY_REGISTERED` when another application
    /// holds the combo, and a wrapper that ignored the return value would
    /// advertise a shortcut that can never fire.
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

    /// Give the chord back to the rest of the desktop.
    ///
    /// Explicit rather than left to `deinit`, for the same reason the sharer's
    /// overlay and injector are: "stop holding this" has to mean now, and a
    /// released hotkey that is still registered is a key another app cannot
    /// have.
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

/// `drain()` and `release()` were already exactly the shape the portable
/// controller wants — the conformance only names that. Declared here rather
/// than in the app so neither swift-cross-ui host needs a `@retroactive`
/// conformance of an imported type to an imported protocol.
extension WindowsHotkey: GlobalHotkeyHolding {}
