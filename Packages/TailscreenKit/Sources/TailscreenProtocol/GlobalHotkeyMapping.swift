import Foundation

// Turning a `ShortcutCatalog` row into something an OS will accept as a
// SYSTEM-WIDE hotkey.
//
// `ShortcutCatalog` describes a chord for a human — "⌃⌥M" / "Ctrl+Alt+M" — and
// deliberately stops there. Registering one with the OS needs a different
// vocabulary per platform: X11 wants a keycode (derived from a keysym) plus a
// modifier bitmask, Win32 wants a virtual-key code plus its own bitmask. Both
// translations are pure arithmetic over tables this package already has and
// tests, so both live here rather than in the two C shims, where Linux CI could
// not see them and where a wrong constant would be a key that silently does
// nothing on somebody else's desk.
//
// One rule is shared and is the reason both entry points are failable rather
// than total: **a chord with no modifiers is refused.** A bare key registered
// system-wide is taken away from every other app on the machine, and the OS
// will happily grant it.

extension ShortcutKey {
    /// This key as a USB HID keyboard-page (0x07) usage ID — the vocabulary
    /// ``X11KeyCodeMapping`` and ``WindowsKeyCodeMapping`` are keyed by.
    ///
    /// Going through HID rather than writing a third `ShortcutKey` → native
    /// table is the whole point: those two tables are already audited against
    /// Xlib's own keysym names (`xtest-probe --audit-keysyms`) and pinned by
    /// unit tests, so a hotkey inherits that coverage instead of adding a
    /// fourth hand-written list of hex constants to keep in agreement.
    ///
    /// `nil` for anything that is not a physical key. `"+"` is the live case:
    /// the catalog spells the zoom-in shortcut that way because it is what a
    /// person reads, but on a US layout there is no `+` key — it is Shift and
    /// the `=` key. Registering a global hotkey on `=` because the label said
    /// `+` would fire on the wrong keystroke, so this returns nil and the
    /// caller declines rather than guessing.
    public var hidUsage: UInt16? {
        switch self {
        case .escape: return 0x29
        // ⌫ is Backspace, HID 0x2A. (HID 0x4C is forward Delete, a different
        // key; the catalog's glyph names the one above Return.)
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

/// Why a host cannot hold a system-wide hotkey.
///
/// A capability that reports "unavailable" rather than pretending, in the same
/// family as `XTestInjector.isTrusted()` and `ts_gtk_overlay_supported()`. The
/// failure it prevents is specific and nasty: a mute hotkey that was never
/// registered looks exactly like a mute hotkey that works, right up to the
/// moment somebody presses it believing they have gone quiet.
///
/// Shared across platforms because the *reasons* are: both `XGrabKey` and
/// `RegisterHotKey` refuse a chord another application already owns, and both
/// hosts have to say so the same way.
/// `Error` so a host that models "held or not" as a `Result` can carry the
/// reason directly; the X11 side returns it as a plain optional instead,
/// because there its grab is a step after opening rather than the whole
/// operation.
public enum GlobalHotkeyUnavailability: Error, Equatable, Sendable {
    /// No X display to open — a headless run, or `$DISPLAY` unset.
    case noDisplay
    /// A Wayland session. `XGrabKey` still *succeeds* against XWayland, which
    /// is the trap: the grab is real but XWayland only ever sees keystrokes
    /// routed to X11 clients, so the chord fires while an X11 app is focused
    /// and does nothing while a native Wayland app is — which is most of the
    /// time, and is worse than not having it, because it works often enough to
    /// be trusted. Wayland's answer is the GlobalShortcuts portal, which is a
    /// separate piece of work (see the ScreenCast portal for the shape of it).
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
    /// A keysym plus the modifier mask to grab it under.
    ///
    /// A keysym, not a keycode, for the same reason ``X11KeyCodeMapping`` is:
    /// a keycode names a physical key on whichever machine is running the X
    /// server and is meaningless until a live `Display *` resolves it. The
    /// `XKeysymToKeycode` hop belongs to the C shim; everything above it is
    /// here.
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

    /// The keysym + mask for `chord`, or nil if it cannot be grabbed.
    ///
    /// Nil in two cases, both deliberate: an unmappable key (see
    /// ``ShortcutKey/hidUsage``) and a chord with **no modifiers**, which
    /// `XGrabKey` would accept and which would then swallow that key for every
    /// other client on the display.
    public static func grab(for chord: ShortcutChord) -> Grab? {
        guard !chord.modifiers.isEmpty else { return nil }
        guard let usage = chord.key.hidUsage,
            let keysym = X11KeyCodeMapping.keysymByHIDUsage[usage]
        else { return nil }
        return Grab(keysym: keysym, modifierMask: modifierMask(chord.modifiers))
    }

    /// Role modifiers → X11 mask.
    ///
    /// `primary` is Ctrl off macOS, so it and `.control` fold onto the same
    /// bit. That collapse is exactly what `ShortcutCatalog.collisions(.words)`
    /// exists to police, and it is harmless here: the mask is a set, so naming
    /// the bit twice sets it once.
    public static func modifierMask(_ modifiers: ShortcutModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.control) || modifiers.contains(.primary) { mask |= controlMask }
        if modifiers.contains(.option) { mask |= mod1Mask }
        if modifiers.contains(.shift) { mask |= shiftMask }
        return mask
    }

    /// Every mask the grab must actually be installed under.
    ///
    /// `XGrabKey` matches the modifier state **exactly**. Grab `Ctrl+Alt+M`
    /// and the hotkey works — until the user presses Num Lock, at which point
    /// the state carries `Mod2Mask` as well, no longer matches, and the key
    /// does nothing with no error anywhere. Caps Lock and Scroll Lock do the
    /// same. The universal X11 idiom is to grab the base mask once per subset
    /// of the "don't care" locks, which is what this enumerates: 2³ = 8 masks,
    /// in a stable order so a failure names a reproducible one.
    ///
    /// This is the single most likely way for the Linux half to look broken
    /// while every unit test passes, which is why it is a list rather than a
    /// comment.
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
    /// Suppress the WM_HOTKEY storm a held-down chord would otherwise produce.
    ///
    /// Not an optimisation. Without it, holding the mute chord flips the mute
    /// latch at the keyboard's auto-repeat rate, so whether the microphone
    /// ends up on or off depends on how long a finger rested on a key — which
    /// is the worst possible property for a mute control. Windows gives this
    /// for free; the X11 side has to build the equivalent out of
    /// ``GlobalHotkeyRepeatFilter``.
    public static let modNoRepeat: UInt32 = 0x4000

    /// The registration for `chord`, or nil if it cannot be registered.
    ///
    /// Same two refusals as the X11 side: an unmappable key, and a chord with
    /// no modifiers (`RegisterHotKey` would take it and no other app on the
    /// machine would see that key again).
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

/// Collapses an X11 key-repeat burst into the one press a person made.
///
/// X11 has no `MOD_NOREPEAT`. Holding the chord delivers a stream of
/// `KeyPress` events, and feeding those straight to a *toggle* means the
/// microphone's final state is decided by how long a finger rested on the key.
///
/// The filter is a latch, not a debounce, on purpose: a debounce would also
/// swallow a deliberate fast double-tap (mute, glance, unmute), which people do.
/// A latch swallows only what is definitionally a repeat — a press with no
/// release in between.
///
/// It relies on the shim asking for `XkbSetDetectableAutoRepeat`, without which
/// a held key delivers release/press pairs that no latch can tell from real
/// ones. That request is reported rather than assumed, so a server that refuses
/// it says so instead of quietly machine-gunning the mute.
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

    /// Forget any held state — for a re-grab, where the release that would
    /// have cleared the latch was delivered to whoever held the grab before.
    public mutating func reset() {
        isDown = false
    }
}
