import Foundation

/// Mapping from USB HID keyboard-page (0x07) usage IDs — the platform-neutral
/// keycode vocabulary ``InputEvent`` carries on the wire — to X11 **keysyms**.
///
/// The third member of the family, after ``MacKeyCodeMapping`` and
/// ``WindowsKeyCodeMapping``, and portable for the same reason: the values are
/// X11-specific, but the table is what lets any peer interoperate with an X11
/// endpoint, and keeping it here means Linux CI tests it.
///
/// **Keysyms, not keycodes**, and the distinction is the whole design. An X11
/// *keycode* is a small integer identifying a physical key on the machine
/// currently running the server; which key that is depends on the loaded
/// keymap, so keycodes are meaningless off-host and unstable across sessions.
/// A *keysym* is the symbol a key produces — `XK_a`, `XK_Return` — and is a
/// fixed, protocol-defined constant. So the portable half is HID → keysym, and
/// the display-dependent half is keysym → keycode via `XKeysymToKeycode`,
/// which lives in the injector's C shim where a live `Display *` exists.
///
/// That split is also what makes this testable at all: without it the mapping
/// would only be checkable on a machine with an X server and a known keymap,
/// which is to say nowhere reliable.
///
/// One direction only, unlike the mac and Windows tables. Those are bijective
/// because their platforms both send *and* receive keystrokes; the Linux
/// sharer only injects, and the Linux **viewer** captures GDK keyvals through
/// `ViewerInputMapping` rather than inverting this. Inverting it would be
/// wrong anyway: several HID usages here map to the same keysym family, and an
/// inverse would have to pick.
public enum X11KeyCodeMapping {
    /// HID keyboard-page usage ID → X11 keysym.
    ///
    /// Letters and digits fold in programmatically: X11 defines the unshifted
    /// letters as their ASCII lowercase values (`XK_a` == 0x0061) and the
    /// digits as ASCII too (`XK_0` == 0x0030), both contiguous. Writing 36
    /// rows by hand would be 36 chances to typo a value that fails silently —
    /// the same reasoning ``WindowsKeyCodeMapping`` gives.
    ///
    /// **Lowercase letters deliberately.** Shift is delivered as a real key
    /// event around the keystroke (see the injector), so mapping to `XK_A`
    /// here would mean Shift is applied twice and every capital arrives as
    /// something else on layouts where shift+A is not A.
    public static let keysymByHIDUsage: [UInt16: UInt32] = {
        var table: [UInt16: UInt32] = [:]

        // Letters: HID 0x04–0x1D → XK_a–XK_z (0x0061–0x007A).
        for offset in 0..<26 {
            table[UInt16(0x04 + offset)] = UInt32(0x0061 + offset)
        }
        // Digits: HID 0x1E–0x26 → XK_1–XK_9, then HID 0x27 → XK_0. Zero is
        // LAST in HID's ordering and first in ASCII's — the one place the two
        // sequences disagree, and an off-by-one here shifts every digit.
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

            // F1–F12 (XK_F1 == 0xFFBE) then F13–F20 (XK_F13 == 0xFFCA);
            // contiguous on both sides, but NOT contiguous with each other —
            // 0xFFC9 is F12 and 0xFFCA is F13, so the two runs join, while the
            // HID side jumps from 0x45 to 0x68.
            0x3A: 0xFFBE, 0x3B: 0xFFBF, 0x3C: 0xFFC0, 0x3D: 0xFFC1,
            0x3E: 0xFFC2, 0x3F: 0xFFC3, 0x40: 0xFFC4, 0x41: 0xFFC5,
            0x42: 0xFFC6, 0x43: 0xFFC7, 0x44: 0xFFC8, 0x45: 0xFFC9,
            0x68: 0xFFCA, 0x69: 0xFFCB, 0x6A: 0xFFCC, 0x6B: 0xFFCD,
            0x6C: 0xFFCE, 0x6D: 0xFFCF, 0x6E: 0xFFD0, 0x6F: 0xFFD1,

            // Navigation cluster. X11 needs no extended-key bit — the keypad
            // twins have their OWN keysyms (XK_KP_Home etc.), which is why
            // this table is a plain UInt32 where the Windows one had to be a
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
            // HID has two names for the context-menu key — "Application"
            // (0x65) and "Menu" (0x76) — and keyboards send either. Both land
            // on XK_Menu, which is the only duplicate value in this table and
            // is fine precisely because the mapping is one-directional: there
            // is no inverse that would have to choose between them.
            0x65: 0xFF67,  // Application → XK_Menu

            // Modifiers, left and right distinguished — X11 has separate
            // keysyms for each side, so unlike Windows there is no ambiguity
            // to resolve and no generic form to avoid.
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

    /// HID usages a peer may legitimately send that this platform does not
    /// inject, with the reason each is out.
    ///
    /// Named rather than merely absent, so "we chose not to map this" is
    /// distinguishable from "we forgot" and a test can assert the set exactly
    /// — adding one later becomes a deliberate act rather than a silent
    /// widening. Same contract as ``WindowsKeyCodeMapping/deliberatelyUnmapped``,
    /// though the membership differs: X11's problem cases are the ones whose
    /// keysym depends on which IME or national layout is loaded, and X11 has
    /// *more* dedicated keysyms than Windows has virtual keys, so the set is
    /// smaller.
    public static let deliberatelyUnmapped: Set<UInt16> = [
        0x67,  // Keypad = — XK_KP_Equal exists but is absent from most keymaps,
        //         so XKeysymToKeycode returns 0 and the press vanishes anyway
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
    /// The left-hand variants, because a modifier has to be *some* physical
    /// key and the wire's ``KeyModifiers`` says only that one was held — the
    /// same choice the Windows injector makes with `VK_CONTROL` vs.
    /// `VK_LCONTROL`.
    ///
    /// **Caps Lock is absent on purpose.** It is a toggle rather than a held
    /// modifier, so synthesizing a press would flip the sharer's actual Caps
    /// state and leave it flipped after the viewer disconnects.
    public static func modifierKeysyms(_ modifiers: KeyModifiers) -> [UInt32] {
        var keys: [UInt32] = []
        if modifiers.contains(.control) { keys.append(0xFFE3) }  // XK_Control_L
        if modifiers.contains(.shift) { keys.append(0xFFE1) }  // XK_Shift_L
        if modifiers.contains(.alt) { keys.append(0xFFE9) }  // XK_Alt_L
        if modifiers.contains(.meta) { keys.append(0xFFEB) }  // XK_Super_L
        return keys
    }
}
