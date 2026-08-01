import Foundation

/// Bidirectional mapping between Windows keys and USB HID keyboard-page (0x07)
/// usage IDs — the platform-neutral keycode vocabulary ``InputEvent`` carries
/// on the wire.
///
/// The Windows counterpart of ``MacKeyCodeMapping``, and portable for the same
/// reason: its *values* are Windows-specific, but every peer needs the table to
/// interoperate with a Windows endpoint, and keeping it here means Linux CI
/// tests it. Neither endpoint ever puts a native keycode on the wire — a mac
/// sharer receiving from a Windows viewer translates HID → kVK, a Windows
/// sharer receiving from a mac viewer translates HID → VK, and the wire carries
/// HID either way.
public enum WindowsKeyCodeMapping {
    /// A Windows key identity: a virtual-key code **and** the extended-key bit.
    ///
    /// The pair, not the code alone, because Windows genuinely identifies keys
    /// that way. Keypad Enter and Return share `VK_RETURN` and are told apart
    /// only by the extended bit; so do Home and keypad-7, Right Alt and Left
    /// Alt. Modelling the bit as a separate lookaside list — which the first
    /// version of this file did — makes the map non-injective the moment
    /// keypad Enter is added, and leaves two things that must agree and can
    /// drift.
    ///
    /// Omitting the bit does not fail loudly: it injects the *other* key. Home
    /// arrives as keypad-7 whenever NumLock is off, which reads as "the arrow
    /// keys are broken" rather than as a missing flag.
    public struct WindowsKey: Hashable, Sendable {
        public let virtualKey: UInt16
        public let isExtended: Bool

        public init(_ virtualKey: UInt16, extended: Bool = false) {
            self.virtualKey = virtualKey
            self.isExtended = extended
        }
    }

    /// HID keyboard-page usage ID → Windows key.
    ///
    /// Letters and digits are folded in programmatically because Windows
    /// defines them as their ASCII values (`VK_A` == 0x41, `VK_0` == 0x30) with
    /// no symbolic constant, and both sequences are contiguous — writing 36
    /// rows by hand would be 36 chances to typo a value that fails silently.
    public static let windowsKeyByHIDUsage: [UInt16: WindowsKey] = {
        var table: [UInt16: WindowsKey] = [:]

        // Letters: HID 0x04–0x1D → VK 'A'–'Z' (0x41–0x5A).
        for offset in 0..<26 {
            table[UInt16(0x04 + offset)] = WindowsKey(UInt16(0x41 + offset))
        }
        // Digits: HID 0x1E–0x26 → VK '1'–'9', then HID 0x27 → VK '0'. Zero is
        // LAST in HID's ordering and first in ASCII's — the one place the two
        // sequences disagree, and an off-by-one here shifts every digit.
        for offset in 0..<9 {
            table[UInt16(0x1E + offset)] = WindowsKey(UInt16(0x31 + offset))
        }
        table[0x27] = WindowsKey(0x30)  // 0

        let rest: [UInt16: WindowsKey] = [
            0x28: WindowsKey(0x0D),  // Return          → VK_RETURN
            0x29: WindowsKey(0x1B),  // Escape          → VK_ESCAPE
            0x2A: WindowsKey(0x08),  // Backspace       → VK_BACK
            0x2B: WindowsKey(0x09),  // Tab             → VK_TAB
            0x2C: WindowsKey(0x20),  // Space           → VK_SPACE
            0x2D: WindowsKey(0xBD),  // -               → VK_OEM_MINUS
            0x2E: WindowsKey(0xBB),  // =               → VK_OEM_PLUS
            0x2F: WindowsKey(0xDB),  // [               → VK_OEM_4
            0x30: WindowsKey(0xDD),  // ]               → VK_OEM_6
            0x31: WindowsKey(0xDC),  // backslash       → VK_OEM_5
            0x33: WindowsKey(0xBA),  // ;               → VK_OEM_1
            0x34: WindowsKey(0xDE),  // '               → VK_OEM_7
            0x35: WindowsKey(0xC0),  // `               → VK_OEM_3
            0x36: WindowsKey(0xBC),  // ,               → VK_OEM_COMMA
            0x37: WindowsKey(0xBE),  // .               → VK_OEM_PERIOD
            0x38: WindowsKey(0xBF),  // /               → VK_OEM_2
            0x39: WindowsKey(0x14),  // CapsLock        → VK_CAPITAL
            0x64: WindowsKey(0xE2),  // Non-US \ and |  → VK_OEM_102

            // F1–F12 then F13–F20; contiguous on both sides.
            0x3A: WindowsKey(0x70), 0x3B: WindowsKey(0x71),
            0x3C: WindowsKey(0x72), 0x3D: WindowsKey(0x73),
            0x3E: WindowsKey(0x74), 0x3F: WindowsKey(0x75),
            0x40: WindowsKey(0x76), 0x41: WindowsKey(0x77),
            0x42: WindowsKey(0x78), 0x43: WindowsKey(0x79),
            0x44: WindowsKey(0x7A), 0x45: WindowsKey(0x7B),
            0x68: WindowsKey(0x7C), 0x69: WindowsKey(0x7D),
            0x6A: WindowsKey(0x7E), 0x6B: WindowsKey(0x7F),
            0x6C: WindowsKey(0x80), 0x6D: WindowsKey(0x81),
            0x6E: WindowsKey(0x82), 0x6F: WindowsKey(0x83),

            // Navigation cluster — all extended, all sharing a virtual-key
            // code with a keypad twin.
            0x46: WindowsKey(0x2C, extended: true),  // PrintScreen → VK_SNAPSHOT
            0x47: WindowsKey(0x91),  // ScrollLock  → VK_SCROLL
            0x48: WindowsKey(0x13),  // Pause       → VK_PAUSE
            0x49: WindowsKey(0x2D, extended: true),  // Insert   → VK_INSERT
            0x4A: WindowsKey(0x24, extended: true),  // Home     → VK_HOME
            0x4B: WindowsKey(0x21, extended: true),  // PageUp   → VK_PRIOR
            0x4C: WindowsKey(0x2E, extended: true),  // Delete   → VK_DELETE
            0x4D: WindowsKey(0x23, extended: true),  // End      → VK_END
            0x4E: WindowsKey(0x22, extended: true),  // PageDown → VK_NEXT
            0x4F: WindowsKey(0x27, extended: true),  // Right    → VK_RIGHT
            0x50: WindowsKey(0x25, extended: true),  // Left     → VK_LEFT
            0x51: WindowsKey(0x28, extended: true),  // Down     → VK_DOWN
            0x52: WindowsKey(0x26, extended: true),  // Up       → VK_UP
            0x75: WindowsKey(0x2F),  // Help        → VK_HELP

            // Numeric keypad. Keypad Enter is VK_RETURN with the extended bit —
            // the case that forced this table to key on the pair.
            0x53: WindowsKey(0x90, extended: true),  // NumLock  → VK_NUMLOCK
            0x54: WindowsKey(0x6F, extended: true),  // /        → VK_DIVIDE
            0x55: WindowsKey(0x6A),  // *           → VK_MULTIPLY
            0x56: WindowsKey(0x6D),  // -           → VK_SUBTRACT
            0x57: WindowsKey(0x6B),  // +           → VK_ADD
            0x58: WindowsKey(0x0D, extended: true),  // Enter    → VK_RETURN
            0x59: WindowsKey(0x61), 0x5A: WindowsKey(0x62), 0x5B: WindowsKey(0x63),
            0x5C: WindowsKey(0x64), 0x5D: WindowsKey(0x65), 0x5E: WindowsKey(0x66),
            0x5F: WindowsKey(0x67), 0x60: WindowsKey(0x68), 0x61: WindowsKey(0x69),
            0x62: WindowsKey(0x60),  // 0           → VK_NUMPAD0
            0x63: WindowsKey(0x6E),  // .           → VK_DECIMAL

            0x65: WindowsKey(0x5D, extended: true),  // Menu     → VK_APPS

            // Volume: HID's keyboard page defines these, so no consumer-page
            // detour is needed.
            0x7F: WindowsKey(0xAD),  // Mute        → VK_VOLUME_MUTE
            0x80: WindowsKey(0xAF),  // Up          → VK_VOLUME_UP
            0x81: WindowsKey(0xAE),  // Down        → VK_VOLUME_DOWN

            // Modifiers, left and right distinguished. The generic VK_SHIFT /
            // VK_CONTROL / VK_MENU are absent on purpose: injecting a modifier
            // without a side is ambiguous, and the wire carries modifier state
            // in `KeyModifiers` separately.
            0xE0: WindowsKey(0xA2),  // LeftControl  → VK_LCONTROL
            0xE1: WindowsKey(0xA0),  // LeftShift    → VK_LSHIFT
            0xE2: WindowsKey(0xA4),  // LeftAlt      → VK_LMENU
            0xE3: WindowsKey(0x5B, extended: true),  // LeftGUI  → VK_LWIN
            0xE4: WindowsKey(0xA3, extended: true),  // RightCtl → VK_RCONTROL
            0xE5: WindowsKey(0xA1),  // RightShift   → VK_RSHIFT
            0xE6: WindowsKey(0xA5, extended: true),  // RightAlt → VK_RMENU
            0xE7: WindowsKey(0x5C, extended: true)  // RightGUI → VK_RWIN
        ]
        table.merge(rest) { existing, _ in existing }
        return table
    }()

    /// Windows key → HID keyboard-page usage ID.
    ///
    /// Derived by inverting the forward table rather than written out, so the
    /// two directions cannot disagree — the same construction
    /// ``MacKeyCodeMapping`` uses, and what makes its bijectivity test mean
    /// something.
    public static let hidUsageByWindowsKey: [WindowsKey: UInt16] = Dictionary(
        windowsKeyByHIDUsage.map { ($0.value, $0.key) },
        uniquingKeysWith: { existing, _ in existing })

    /// HID usages a peer may legitimately send that this platform does not
    /// inject, with the reason each is out.
    ///
    /// Named rather than merely absent so that "we chose not to map this" is
    /// distinguishable from "we forgot", and so a test can assert the set
    /// exactly — adding one later becomes a deliberate act instead of a silent
    /// widening.
    ///
    /// All six are keyboard-layout- or IME-dependent on Windows: their virtual
    /// key depends on the active layout rather than on the physical key, so a
    /// fixed table would inject the wrong character on most layouts. Dropping
    /// the keystroke is the lesser failure — a key that does nothing is
    /// noticed and understood; a key that types something else is not.
    public static let deliberatelyUnmapped: Set<UInt16> = [
        0x67,  // Keypad = — VK_OEM_NEC_EQUAL only on NEC layouts
        0x85,  // Keypad , — VK_ABNT_C2 on ABNT, VK_SEPARATOR elsewhere
        0x87,  // International1 (JIS Ro)
        0x89,  // International3 (JIS Yen)
        0x90,  // LANG1 (Hangul / Kana toggle)
        0x91  // LANG2 (Hanja / Eisu toggle)
    ]

    /// Translate a HID usage to the Windows key that injects it, or nil when
    /// this platform has no unambiguous equivalent. A nil is dropped, never
    /// guessed at.
    public static func windowsKey(forHIDUsage usage: UInt16) -> WindowsKey? {
        windowsKeyByHIDUsage[usage]
    }

    /// Translate a Windows key to its HID usage, for a future Windows *viewer*
    /// capturing keystrokes to send. Unused by the sharer, which only injects.
    public static func hidUsage(forVirtualKey key: UInt16, extended: Bool = false) -> UInt16? {
        hidUsageByWindowsKey[WindowsKey(key, extended: extended)]
    }
}
