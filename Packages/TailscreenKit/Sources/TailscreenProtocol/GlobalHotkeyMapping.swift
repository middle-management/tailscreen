import Foundation

// Turns a `ShortcutCatalog` chord into a SYSTEM-WIDE hotkey registration: X11
// wants a keysym-derived keycode + modifier bitmask, Win32 a virtual-key code
// + its own bitmask. Pure arithmetic, kept here (not the C shims) so Linux CI
// can test it.
//
// Shared rule, why both entry points are failable: **a chord with no
// modifiers is refused** — the OS would grant it, taking that bare key from
// every other app on the machine.

extension ShortcutKey {
    /// This key as a USB HID keyboard-page (0x07) usage ID — the vocabulary
    /// ``X11KeyCodeMapping`` and ``WindowsKeyCodeMapping`` are keyed by.
    /// Going through HID reuses those already-audited tables instead of a
    /// third hand-written list.
    ///
    /// `nil` for anything that is not a physical key. `"+"` is the live case:
    /// on a US layout there is no `+` key, only Shift+`=`, so mapping it to
    /// `=` would fire the wrong keystroke — return nil and let the caller
    /// decline rather than guess.
    public var hidUsage: UInt16? {
        switch self {
        case .escape: return 0x29
        // ⌫ = Backspace (HID 0x2A), not forward Delete (0x4C).
        case .delete: return 0x2A
        case .character(let raw):
            let value = raw.lowercased()
            guard value.count == 1, let scalar = value.unicodeScalars.first else { return nil }
            if scalar >= "a" && scalar <= "z" {
                return UInt16(0x04 + (scalar.value - UnicodeScalar("a").value))
            }
            // HID puts 1–9 first and 0 last; ASCII puts 0 first.
            if scalar >= "1" && scalar <= "9" {
                return UInt16(0x1E + (scalar.value - UnicodeScalar("1").value))
            }
            if scalar == "0" { return 0x27 }
            return Self.punctuationHIDUsage[Character(scalar)]
        }
    }

    /// The punctuation a chord can legitimately name. Deliberately only the
    /// keys that exist unshifted on a US layout — see `hidUsage` on `"+"`.
    private static let punctuationHIDUsage: [Character: UInt16] = [
        " ": 0x2C,
        "-": 0x2D,
        "=": 0x2E,
        "[": 0x2F,
        "]": 0x30,
        "\\": 0x31,
        ";": 0x33,
        "'": 0x34,
        "`": 0x35,
        ",": 0x36,
        ".": 0x37,
        "/": 0x38
    ]
}

/// Why a host cannot hold a system-wide hotkey — reports "unavailable" rather
/// than pretending, since a mute hotkey that silently never registered looks
/// identical to a working one until someone presses it.
///
/// `Error` so a host modeling "held or not" as a `Result` can carry the
/// reason directly; the X11 side returns it as a plain optional since its
/// grab is a step after opening rather than the whole operation.
public enum GlobalHotkeyUnavailability: Error, Equatable, Sendable {
    /// No X display to open — a headless run, or `$DISPLAY` unset.
    case noDisplay
    /// A Wayland session. `XGrabKey` still *succeeds* against XWayland, but
    /// only fires while an X11 app is focused — worse than unavailable,
    /// because it works often enough to be trusted. Wayland's answer is the
    /// GlobalShortcuts portal (separate work).
    case waylandSession
    /// The chord cannot be expressed as a registration: an unmappable key, or
    /// one with no modifiers, which would take that key from every other app.
    case unmappableChord
    /// The OS refused: another application already owns the combo (X11's
    /// `BadAccess`, Win32's `ERROR_HOTKEY_ALREADY_REGISTERED`), or this keymap
    /// has no key for it. First registration wins on both platforms.
    case alreadyOwned
    /// This build has no global-hotkey mechanism at all — the shape a Windows
    /// wrapper takes when compiled on Linux for typechecking.
    case unsupportedPlatform

    /// English source text for the host to show or log. Hosts localize.
    public var reason: String {
        switch self {
        case .noDisplay: "no X display"
        case .waylandSession:
            "Wayland sessions do not deliver global hotkeys to X11 clients"
        case .unmappableChord: "the shortcut cannot be registered system-wide"
        case .alreadyOwned: "another application already owns this shortcut"
        case .unsupportedPlatform: "this platform has no system-wide shortcuts"
        }
    }
}

/// A `ShortcutChord` expressed as an `XGrabKey` request.
public enum X11HotkeyMapping {
    /// A keysym plus the modifier mask to grab it under. A keysym, not a
    /// keycode: a keycode is meaningless until a live `Display *` resolves
    /// it, which the C shim's `XKeysymToKeycode` hop handles.
    public struct Grab: Equatable, Sendable {
        public let keysym: UInt32
        public let modifierMask: UInt32

        public init(keysym: UInt32, modifierMask: UInt32) {
            self.keysym = keysym
            self.modifierMask = modifierMask
        }
    }

    // X11's modifier bits (`X.h`). Named here rather than imported so the
    // mapping is testable without an X server anywhere in the picture.
    public static let shiftMask: UInt32 = 1 << 0
    /// Caps Lock.
    public static let lockMask: UInt32 = 1 << 1
    public static let controlMask: UInt32 = 1 << 2
    /// Alt, on every mainstream layout.
    public static let mod1Mask: UInt32 = 1 << 3
    /// Num Lock, on every mainstream layout.
    public static let mod2Mask: UInt32 = 1 << 4
    /// Scroll Lock on the layouts that bind it at all.
    public static let mod5Mask: UInt32 = 1 << 7

    /// The keysym + mask for `chord`, or nil for an unmappable key or a
    /// chord with no modifiers (see ``ShortcutKey/hidUsage``).
    public static func grab(for chord: ShortcutChord) -> Grab? {
        guard !chord.modifiers.isEmpty else { return nil }
        guard let usage = chord.key.hidUsage,
            let keysym = X11KeyCodeMapping.keysymByHIDUsage[usage]
        else { return nil }
        return Grab(keysym: keysym, modifierMask: modifierMask(chord.modifiers))
    }

    /// Role modifiers → X11 mask. `.primary` (Ctrl off macOS) and `.control`
    /// fold onto the same bit; harmless since the mask is a set.
    public static func modifierMask(_ modifiers: ShortcutModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.control) || modifiers.contains(.primary) { mask |= controlMask }
        if modifiers.contains(.option) { mask |= mod1Mask }
        if modifiers.contains(.shift) { mask |= shiftMask }
        return mask
    }

    /// Every mask the grab must actually be installed under.
    ///
    /// `XGrabKey` matches the modifier state **exactly** — Num/Caps/Scroll
    /// Lock being on adds a bit and silently breaks the grab otherwise. Grab
    /// the base mask once per subset of these "don't care" locks: 2³ = 8
    /// masks, stable order.
    public static func grabMasks(base: UInt32) -> [UInt32] {
        let ignored = [lockMask, mod2Mask, mod5Mask]
        var masks: [UInt32] = []
        for combination in 0..<(1 << ignored.count) {
            var mask = base
            for (index, bit) in ignored.enumerated() where combination & (1 << index) != 0 {
                mask |= bit
            }
            masks.append(mask)
        }
        return masks
    }
}

/// A `ShortcutChord` expressed as a `RegisterHotKey` request.
public enum WindowsHotkeyMapping {
    /// The `fsModifiers` + `vk` pair `RegisterHotKey` takes.
    public struct Registration: Equatable, Sendable {
        public let modifiers: UInt32
        public let virtualKey: UInt32

        public init(modifiers: UInt32, virtualKey: UInt32) {
            self.modifiers = modifiers
            self.virtualKey = virtualKey
        }
    }

    // `winuser.h` values.
    public static let modAlt: UInt32 = 0x0001
    public static let modControl: UInt32 = 0x0002
    public static let modShift: UInt32 = 0x0004
    public static let modWin: UInt32 = 0x0008
    /// Suppress the WM_HOTKEY storm a held-down chord would otherwise
    /// produce — without it, holding the mute chord flips the latch at the
    /// keyboard's auto-repeat rate. X11 has no equivalent; see
    /// ``GlobalHotkeyRepeatFilter``.
    public static let modNoRepeat: UInt32 = 0x4000

    /// The registration for `chord`, or nil for an unmappable key or a chord
    /// with no modifiers (same refusals as the X11 side).
    public static func registration(for chord: ShortcutChord) -> Registration? {
        guard !chord.modifiers.isEmpty else { return nil }
        guard let usage = chord.key.hidUsage,
            let key = WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage)
        else { return nil }
        return Registration(
            modifiers: modifierFlags(chord.modifiers), virtualKey: UInt32(key.virtualKey))
    }

    /// Role modifiers → `fsModifiers`, always including `MOD_NOREPEAT`.
    public static func modifierFlags(_ modifiers: ShortcutModifiers) -> UInt32 {
        var flags = modNoRepeat
        if modifiers.contains(.control) || modifiers.contains(.primary) { flags |= modControl }
        if modifiers.contains(.option) { flags |= modAlt }
        if modifiers.contains(.shift) { flags |= modShift }
        return flags
    }
}

/// Collapses an X11 key-repeat burst into the one press a person made. X11
/// has no `MOD_NOREPEAT`; feeding repeated `KeyPress` straight to a toggle
/// would make the mic's final state depend on how long a finger rested.
///
/// A latch, not a debounce — a debounce would also swallow a deliberate fast
/// double-tap. Relies on the shim requesting `XkbSetDetectableAutoRepeat`
/// (reported, not assumed), without which a held key can't be told from
/// real repeated presses.
public struct GlobalHotkeyRepeatFilter: Sendable {
    public enum Event: Sendable, Equatable {
        case press
        case release
    }

    private var isDown = false

    public init() {}

    /// Whether this event is a real activation.
    public mutating func shouldFire(_ event: Event) -> Bool {
        switch event {
        case .press:
            if isDown { return false }
            isDown = true
            return true
        case .release:
            isDown = false
            return false
        }
    }

    /// Forget any held state, for a re-grab whose clearing release went to
    /// the previous holder.
    public mutating func reset() {
        isDown = false
    }
}
