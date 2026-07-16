import Foundation

/// Bidirectional mapping between macOS hardware virtual keycodes (`kVK_*`,
/// what `NSEvent.keyCode` / `CGEvent(keyboardEventSource:virtualKey:)` speak)
/// and USB HID keyboard-page (0x07) usage IDs — the platform-neutral keycode
/// vocabulary ``InputEvent`` carries on the wire.
///
/// Foundation-only on purpose: it's part of the portable TailscreenProtocol
/// set even though its *values* are mac-specific, because every non-mac peer
/// implementation needs this exact reference table to interoperate with mac
/// endpoints (and gets its correctness tests for free on Linux CI). Other
/// platforms pair it with their own native↔HID table (evdev and Windows
/// virtual-key equivalents ship with those systems).
///
/// Coverage: the full ANSI/ISO/JIS key set Apple defines in HIToolbox
/// `Events.h`. Deliberately absent:
/// - `kVK_Function` (0x3F) — fn has no HID keyboard-page usage; PC keyboards
///   handle it in hardware, and macOS translates fn-chords (fn+←/→/↑/↓ →
///   Home/End/PageUp/PageDown) before events reach us.
/// - Consumer-page media keys beyond volume (which HID's keyboard page does
///   define: 0x7F–0x81).
enum MacKeyCodeMapping {
    /// mac virtual keycode (`kVK_*`) → HID keyboard-page usage ID.
    static let hidUsageByMacKeyCode: [UInt16: UInt16] = [
        // Letters (kVK_ANSI_*)
        0x00: 0x04,  // A
        0x0B: 0x05,  // B
        0x08: 0x06,  // C
        0x02: 0x07,  // D
        0x0E: 0x08,  // E
        0x03: 0x09,  // F
        0x05: 0x0A,  // G
        0x04: 0x0B,  // H
        0x22: 0x0C,  // I
        0x26: 0x0D,  // J
        0x28: 0x0E,  // K
        0x25: 0x0F,  // L
        0x2E: 0x10,  // M
        0x2D: 0x11,  // N
        0x1F: 0x12,  // O
        0x23: 0x13,  // P
        0x0C: 0x14,  // Q
        0x0F: 0x15,  // R
        0x01: 0x16,  // S
        0x11: 0x17,  // T
        0x20: 0x18,  // U
        0x09: 0x19,  // V
        0x0D: 0x1A,  // W
        0x07: 0x1B,  // X
        0x10: 0x1C,  // Y
        0x06: 0x1D,  // Z
        // Number row
        0x12: 0x1E,  // 1
        0x13: 0x1F,  // 2
        0x14: 0x20,  // 3
        0x15: 0x21,  // 4
        0x17: 0x22,  // 5
        0x16: 0x23,  // 6
        0x1A: 0x24,  // 7
        0x1C: 0x25,  // 8
        0x19: 0x26,  // 9
        0x1D: 0x27,  // 0
        // Controls
        0x24: 0x28,  // Return → Enter
        0x35: 0x29,  // Escape
        0x33: 0x2A,  // Delete (backspace)
        0x30: 0x2B,  // Tab
        0x31: 0x2C,  // Space
        // Punctuation
        0x1B: 0x2D,  // -
        0x18: 0x2E,  // =
        0x21: 0x2F,  // [
        0x1E: 0x30,  // ]
        0x2A: 0x31,  // \
        0x29: 0x33,  // ;
        0x27: 0x34,  // '
        0x32: 0x35,  // `
        0x2B: 0x36,  // ,
        0x2F: 0x37,  // .
        0x2C: 0x38,  // /
        0x39: 0x39,  // CapsLock
        // Function row
        0x7A: 0x3A,  // F1
        0x78: 0x3B,  // F2
        0x63: 0x3C,  // F3
        0x76: 0x3D,  // F4
        0x60: 0x3E,  // F5
        0x61: 0x3F,  // F6
        0x62: 0x40,  // F7
        0x64: 0x41,  // F8
        0x65: 0x42,  // F9
        0x6D: 0x43,  // F10
        0x67: 0x44,  // F11
        0x6F: 0x45,  // F12
        0x69: 0x68,  // F13
        0x6B: 0x69,  // F14
        0x71: 0x6A,  // F15
        0x6A: 0x6B,  // F16
        0x40: 0x6C,  // F17
        0x4F: 0x6D,  // F18
        0x50: 0x6E,  // F19
        0x5A: 0x6F,  // F20
        // Navigation
        0x72: 0x75,  // Help (HID Help; Macs have no Insert)
        0x73: 0x4A,  // Home
        0x74: 0x4B,  // PageUp
        0x75: 0x4C,  // ForwardDelete → Delete Forward
        0x77: 0x4D,  // End
        0x79: 0x4E,  // PageDown
        0x7C: 0x4F,  // →
        0x7B: 0x50,  // ←
        0x7D: 0x51,  // ↓
        0x7E: 0x52,  // ↑
        // Keypad
        0x47: 0x53,  // KeypadClear → Keypad NumLock/Clear
        0x4B: 0x54,  // Keypad /
        0x43: 0x55,  // Keypad *
        0x4E: 0x56,  // Keypad -
        0x45: 0x57,  // Keypad +
        0x4C: 0x58,  // Keypad Enter
        0x53: 0x59,  // Keypad 1
        0x54: 0x5A,  // Keypad 2
        0x55: 0x5B,  // Keypad 3
        0x56: 0x5C,  // Keypad 4
        0x57: 0x5D,  // Keypad 5
        0x58: 0x5E,  // Keypad 6
        0x59: 0x5F,  // Keypad 7
        0x5B: 0x60,  // Keypad 8
        0x5C: 0x61,  // Keypad 9
        0x52: 0x62,  // Keypad 0
        0x41: 0x63,  // Keypad .
        0x51: 0x67,  // Keypad =
        // ISO / JIS
        0x0A: 0x64,  // ISO Section → Non-US \
        0x5F: 0x85,  // JIS Keypad ,
        0x5E: 0x87,  // JIS Underscore → International1
        0x5D: 0x89,  // JIS Yen → International3
        0x68: 0x90,  // JIS Kana → LANG1
        0x66: 0x91,  // JIS Eisu → LANG2
        // Media (keyboard-page volume trio)
        0x4A: 0x7F,  // Mute
        0x48: 0x80,  // VolumeUp
        0x49: 0x81,  // VolumeDown
        // Menu
        0x6E: 0x65,  // ContextualMenu → Application
        // Modifiers (HID 0xE0–0xE7)
        0x3B: 0xE0,  // Control
        0x38: 0xE1,  // Shift
        0x3A: 0xE2,  // Option → Alt
        0x37: 0xE3,  // Command → GUI
        0x3E: 0xE4,  // RightControl
        0x3C: 0xE5,  // RightShift
        0x3D: 0xE6,  // RightOption
        0x36: 0xE7  // RightCommand
    ]

    /// HID keyboard-page usage ID → mac virtual keycode. Pure inversion of
    /// `hidUsageByMacKeyCode` — the table is bijective (pinned by
    /// `MacKeyCodeMappingTests`), so `uniquingKeysWith` never fires.
    static let macKeyCodeByHIDUsage: [UInt16: UInt16] = Dictionary(
        hidUsageByMacKeyCode.map { ($0.value, $0.key) },
        uniquingKeysWith: { first, _ in first }
    )

    /// HID usage for a mac hardware keycode (viewer-side capture). nil for
    /// keycodes outside the table — the caller should drop the event rather
    /// than guess.
    static func hidUsage(forMacKeyCode keyCode: UInt16) -> UInt16? {
        hidUsageByMacKeyCode[keyCode]
    }

    /// Mac hardware keycode for a wire HID usage (sharer-side injection).
    /// nil for usages with no mac key (e.g. Insert 0x49, PrintScreen 0x46) —
    /// the injector drops those rather than injecting a wrong key.
    static func macKeyCode(forHIDUsage usage: UInt16) -> UInt16? {
        macKeyCodeByHIDUsage[usage]
    }
}
