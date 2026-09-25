import Foundation

/// Maps USB HID keyboard-page (0x07) usage IDs (the wire's neutral keycode
/// vocabulary, see ``InputEvent``) to X11 **keysyms** — not keycodes, which
/// are per-machine, keymap-dependent integers. Keysym → keycode via
/// `XKeysymToKeycode` happens later in the injector's C shim, where a live
/// `Display *` exists; keeping that split here is what makes this table
/// testable without an X server.
///
/// One direction only (sharer injects; the Linux viewer maps GDK keyvals
/// separately via `ViewerInputMapping`) — several HID usages collapse to the
/// same keysym, so there's no clean inverse.
public enum X11KeyCodeMapping {
    /// HID keyboard-page usage ID → X11 keysym.
    ///
    /// Letters/digits are generated: X11's unshifted letters and digits are
    /// ASCII (`XK_a` == 0x0061, `XK_0` == 0x0030), avoiding 36 hand-typed rows.
    ///
    /// **Lowercase deliberately** — Shift is a separate real key event around
    /// the keystroke, so mapping to `XK_A` would apply Shift twice.
    public static let keysymByHIDUsage: [UInt16: UInt32] = {
        var table: [UInt16: UInt32] = [:]

        // Letters: HID 0x04–0x1D → XK_a–XK_z (0x0061–0x007A).
        for offset in 0..<26 {
            table[UInt16(0x04 + offset)] = UInt32(0x0061 + offset)
        }
        // Digits: HID 0x1E–0x26 → XK_1–XK_9, then 0x27 → XK_0 (zero is last
        // in HID order, first in ASCII — the one place they disagree).
        for offset in 0..<9 {
            table[UInt16(0x1E + offset)] = UInt32(0x0031 + offset)
        }
        table[0x27] = 0x0030  // 0

        let rest: [UInt16: UInt32] = [
            0x28: 0xFF0D,  // Return          → XK_Return
            0x29: 0xFF1B,  // Escape          → XK_Escape
            0x2A: 0xFF08,  // Backspace       → XK_BackSpace
            0x2B: 0xFF09,  // Tab             → XK_Tab
            0x2C: 0x0020,  // Space           → XK_space
            0x2D: 0x002D,  // -               → XK_minus
            0x2E: 0x003D,  // =               → XK_equal
            0x2F: 0x005B,  // [               → XK_bracketleft
            0x30: 0x005D,  // ]               → XK_bracketright
            0x31: 0x005C,  // backslash       → XK_backslash
            0x33: 0x003B,  // ;               → XK_semicolon
            0x34: 0x0027,  // '               → XK_apostrophe
            0x35: 0x0060,  // `               → XK_grave
            0x36: 0x002C,  // ,               → XK_comma
            0x37: 0x002E,  // .               → XK_period
            0x38: 0x002F,  // /               → XK_slash
            0x39: 0xFFE5,  // CapsLock        → XK_Caps_Lock
            0x64: 0x003C,  // Non-US \ and |  → XK_less

            // F1–F12 then F13–F20: both runs are keysym-contiguous and join
            // (0xFFC9=F12, 0xFFCA=F13), but the HID side jumps 0x45→0x68.
            0x3A: 0xFFBE, 0x3B: 0xFFBF, 0x3C: 0xFFC0, 0x3D: 0xFFC1,
            0x3E: 0xFFC2, 0x3F: 0xFFC3, 0x40: 0xFFC4, 0x41: 0xFFC5,
            0x42: 0xFFC6, 0x43: 0xFFC7, 0x44: 0xFFC8, 0x45: 0xFFC9,
            0x68: 0xFFCA, 0x69: 0xFFCB, 0x6A: 0xFFCC, 0x6B: 0xFFCD,
            0x6C: 0xFFCE, 0x6D: 0xFFCF, 0x6E: 0xFFD0, 0x6F: 0xFFD1,

            // Navigation cluster. No extended-key bit needed — keypad twins
            // have their own keysyms (XK_KP_Home etc.), unlike the Windows
            // (code, extended) pair.
            0x46: 0xFF61,  // PrintScreen → XK_Print
            0x47: 0xFF14,  // ScrollLock  → XK_Scroll_Lock
            0x48: 0xFF13,  // Pause       → XK_Pause
            0x49: 0xFF63,  // Insert      → XK_Insert
            0x4A: 0xFF50,  // Home        → XK_Home
            0x4B: 0xFF55,  // PageUp      → XK_Prior
            0x4C: 0xFFFF,  // Delete      → XK_Delete
            0x4D: 0xFF57,  // End         → XK_End
            0x4E: 0xFF56,  // PageDown    → XK_Next
            0x4F: 0xFF53,  // Right       → XK_Right
            0x50: 0xFF51,  // Left        → XK_Left
            0x51: 0xFF54,  // Down        → XK_Down
            0x52: 0xFF52,  // Up          → XK_Up
            0x75: 0xFF6A,  // Help        → XK_Help
            0x76: 0xFF67,  // Menu        → XK_Menu
            0x77: 0xFF60,  // Select      → XK_Select
            0x78: 0xFF69,  // Stop        → XK_Cancel
            0x79: 0xFF66,  // Again       → XK_Redo
            0x7A: 0xFF65,  // Undo        → XK_Undo

            // Numeric keypad, all with dedicated keysyms.
            0x53: 0xFF7F,  // NumLock     → XK_Num_Lock
            0x54: 0xFFAF,  // /           → XK_KP_Divide
            0x55: 0xFFAA,  // *           → XK_KP_Multiply
            0x56: 0xFFAD,  // -           → XK_KP_Subtract
            0x57: 0xFFAB,  // +           → XK_KP_Add
            0x58: 0xFF8D,  // Enter       → XK_KP_Enter
            0x59: 0xFFB1, 0x5A: 0xFFB2, 0x5B: 0xFFB3,
            0x5C: 0xFFB4, 0x5D: 0xFFB5, 0x5E: 0xFFB6,
            0x5F: 0xFFB7, 0x60: 0xFFB8, 0x61: 0xFFB9,
            0x62: 0xFFB0,  // 0           → XK_KP_0
            0x63: 0xFFAE,  // .           → XK_KP_Decimal
            // HID's "Application" (0x65) and "Menu" (0x76) both mean the
            // context-menu key; both map to XK_Menu, the only duplicate here
            // (harmless since this direction is never inverted).
            0x65: 0xFF67,  // Application → XK_Menu

            // Left/right distinguished — X11 has separate keysyms per side.
            0xE0: 0xFFE3,  // LeftControl  → XK_Control_L
            0xE1: 0xFFE1,  // LeftShift    → XK_Shift_L
            0xE2: 0xFFE9,  // LeftAlt      → XK_Alt_L
            0xE3: 0xFFEB,  // LeftGUI      → XK_Super_L
            0xE4: 0xFFE4,  // RightControl → XK_Control_R
            0xE5: 0xFFE2,  // RightShift   → XK_Shift_R
            0xE6: 0xFFEA,  // RightAlt     → XK_Alt_R
            0xE7: 0xFFEC  // RightGUI     → XK_Super_R
        ]
        table.merge(rest) { existing, _ in existing }
        return table
    }()

    /// HID usages this platform deliberately does not inject, with the reason
    /// each is out. Named (not merely absent) so a test can assert the set
    /// exactly; see ``WindowsKeyCodeMapping/deliberatelyUnmapped`` for the
    /// analogous contract.
    public static let deliberatelyUnmapped: Set<UInt16> = [
        0x67,  // Keypad = — XK_KP_Equal is absent from most keymaps, so
        //         XKeysymToKeycode returns 0 and the press vanishes anyway
        0x85,  // Keypad , — separator vs. decimal is locale-dependent
        0x87,  // International1 (JIS Ro)
        0x89,  // International3 (JIS Yen)
        0x90,  // LANG1 (Hangul / Kana toggle)
        0x91  // LANG2 (Hanja / Eisu toggle)
    ]

    /// Translate a HID usage to the keysym that injects it, or nil when this
    /// platform has no unambiguous equivalent. A nil is dropped, never guessed
    /// at — the same rule the mac and Windows injectors follow.
    public static func keysym(forHIDUsage usage: UInt16) -> UInt32? {
        keysymByHIDUsage[usage]
    }

    /// The keysyms for a modifier snapshot, in a stable order.
    ///
    /// Left-hand variants, since ``KeyModifiers`` says only that a modifier
    /// was held, not which side.
    ///
    /// **Caps Lock is absent on purpose** — it's a toggle, not a held
    /// modifier; synthesizing a press would flip the sharer's real state and
    /// leave it flipped after disconnect.
    public static func modifierKeysyms(_ modifiers: KeyModifiers) -> [UInt32] {
        var keys: [UInt32] = []
        if modifiers.contains(.control) { keys.append(0xFFE3) }  // XK_Control_L
        if modifiers.contains(.shift) { keys.append(0xFFE1) }  // XK_Shift_L
        if modifiers.contains(.alt) { keys.append(0xFFE9) }  // XK_Alt_L
        if modifiers.contains(.meta) { keys.append(0xFFEB) }  // XK_Super_L
        return keys
    }
}
