import Foundation
import TailscreenProtocol

/// Pure, platform-detail input mapping for the Linux/GTK viewer's opt-in
/// remote-control capture. Kept in Core (Foundation + `TailscreenProtocol`
/// only, no GTK) so it's unit-tested — the GTK event-controller layer only
/// feeds it plain integers and ships the resulting `InputEvent`s.
public enum ViewerInputMapping {
    // MARK: Pointer

    /// Map a widget-space pointer position to normalized `[0, 1]` over the
    /// aspect-fit video content rect (letterbox bars excluded), origin
    /// top-left. Clamped to `[0, 1]` so a letterbox-bar position lands on the
    /// nearest content edge (matches the sharer's own clamp).
    ///
    /// Forwards to ``ViewerPointerMapping/normalize(point:paneSize:videoSize:)``,
    /// which the WinUI viewer shares; kept as a name so no GTK caller changed.
    public static func normalizePointer(
        px: Double, py: Double, widgetW: Double, widgetH: Double,
        videoW: Int, videoH: Int
    ) -> (x: Double, y: Double) {
        ViewerPointerMapping.normalize(
            point: (x: px, y: py), paneSize: (width: widgetW, height: widgetH),
            videoSize: (width: videoW, height: videoH))
    }

    /// GDK mouse button number (1 left, 2 middle, 3 right) → neutral button, or
    /// nil for any other button (back/forward/etc. — dropped, not guessed).
    public static func mouseButton(fromGdk button: Int) -> InputEvent.MouseButton? {
        switch button {
        case 1: return .left
        case 2: return .middle
        case 3: return .right
        default: return nil
        }
    }

    // MARK: Scroll

    /// What a wheel/touchpad scroll over the video should do. While a grant
    /// is live the wheel scrolls the sharer's content, but Ctrl+wheel stays
    /// local for zoom — without that split one of the two is unreachable.
    /// The WinUI viewer makes the identical split (`WinUIVideoView.handleWheel`).
    public enum ScrollDisposition: Equatable, Sendable {
        /// Send it to the sharer as an ``InputEvent/scroll(x:y:deltaX:deltaY:modifiers:)``
        /// with these already-converted **wire** deltas.
        case forward(deltaX: Double, deltaY: Double, modifiers: KeyModifiers)
        /// Keep it: zoom about the cursor, or pan while Shift is held.
        case local
    }

    /// Decide, and convert GDK's delta convention to the wire's.
    ///
    /// The vertical sign flip is load-bearing: GDK reports `dy > 0` for
    /// scrolling down, but the wire reads positive `deltaY` as up. Horizontal
    /// needs no flip.
    public static func scrollDisposition(
        dx: Double, dy: Double, gdkState: UInt, isControlling: Bool
    ) -> ScrollDisposition {
        let modifiers = keyModifiers(fromGdkState: gdkState)
        guard isControlling, !modifiers.contains(.control) else { return .local }
        return .forward(deltaX: dx, deltaY: -dy, modifiers: modifiers)
    }

    // MARK: Modifiers

    // GDK4 `GdkModifierType` bit values (gdk/gdkenums.h) — ABI-stable, so the GTK
    // layer passes the raw bitmask and we read the bits here.
    static let gdkShiftMask: UInt = 1 << 0
    static let gdkLockMask: UInt = 1 << 1  // Caps Lock
    static let gdkControlMask: UInt = 1 << 2
    static let gdkAltMask: UInt = 1 << 3  // GDK_ALT_MASK (formerly GDK_MOD1_MASK)
    static let gdkSuperMask: UInt = 1 << 26  // Super / Windows key → `.meta`

    /// `GdkModifierType` raw bitmask → neutral ``KeyModifiers``. Only the
    /// five wire-defined bits are extracted; the sharer reconstructs native
    /// flags from exactly these.
    public static func keyModifiers(fromGdkState state: UInt) -> KeyModifiers {
        var mods: KeyModifiers = []
        if state & gdkShiftMask != 0 { mods.insert(.shift) }
        if state & gdkControlMask != 0 { mods.insert(.control) }
        if state & gdkAltMask != 0 { mods.insert(.alt) }
        if state & gdkSuperMask != 0 { mods.insert(.meta) }
        if state & gdkLockMask != 0 { mods.insert(.capsLock) }
        return mods
    }

    // MARK: Keyboard

    /// Map a GDK hardware keycode to a USB HID keyboard-page (0x07) usage ID,
    /// or nil if unmapped (dropped, never guessed).
    ///
    /// `hardware_keycode == evdev keycode + 8` (X11/xkb convention, also used
    /// on Wayland). Maps the physical key (position), not the layout symbol —
    /// layout interpretation stays on the sharer's machine.
    public static func hidUsage(fromGdkHardwareKeycode keycode: Int) -> UInt16? {
        evdevToHID[keycode - 8]
    }

    /// True for HID usages that are modifier keys (0xE0–0xE7) — not sent as
    /// standalone key events; their held state rides `modifiers`. Answered
    /// from the shared `KeyModifiers.heldModifier(forHIDUsage:)` table so it
    /// can't disagree with the WinUI viewer's copy. Caps Lock (0x39) is
    /// deliberately excluded — GDK reports it in the modifier mask instead.
    public static func isModifierUsage(_ usage: UInt16) -> Bool {
        KeyModifiers.heldModifier(forHIDUsage: usage) != nil
    }

    /// evdev keycode → USB HID usage. Standard US-keyboard subset (letters,
    /// digits, punctuation, function/keypad/editing/arrow keys, modifiers);
    /// anything not listed is dropped. Source: `linux/input-event-codes.h`
    /// cross-referenced with the USB HID Usage Tables keyboard/keypad page.
    static let evdevToHID: [Int: UInt16] = [
        1: 0x29,  // ESC
        2: 0x1E, 3: 0x1F, 4: 0x20, 5: 0x21, 6: 0x22,  // 1 2 3 4 5
        7: 0x23, 8: 0x24, 9: 0x25, 10: 0x26, 11: 0x27,  // 6 7 8 9 0
        12: 0x2D, 13: 0x2E,  // - =
        14: 0x2A, 15: 0x2B,  // Backspace, Tab
        16: 0x14, 17: 0x1A, 18: 0x08, 19: 0x15, 20: 0x17,  // Q W E R T
        21: 0x1C, 22: 0x18, 23: 0x0C, 24: 0x12, 25: 0x13,  // Y U I O P
        26: 0x2F, 27: 0x30,  // [ ]
        28: 0x28,  // Enter
        29: 0xE0,  // LeftCtrl
        30: 0x04, 31: 0x16, 32: 0x07, 33: 0x09, 34: 0x0A,  // A S D F G
        35: 0x0B, 36: 0x0D, 37: 0x0E, 38: 0x0F,  // H J K L
        39: 0x33, 40: 0x34, 41: 0x35,  // ; ' `
        42: 0xE1, 43: 0x31,  // LeftShift, Backslash
        44: 0x1D, 45: 0x1B, 46: 0x06, 47: 0x19, 48: 0x05,  // Z X C V B
        49: 0x11, 50: 0x10,  // N M
        51: 0x36, 52: 0x37, 53: 0x38,  // , . /
        54: 0xE5,  // RightShift
        55: 0x55,  // Keypad *
        56: 0xE2,  // LeftAlt
        57: 0x2C,  // Space
        58: 0x39,  // CapsLock
        59: 0x3A, 60: 0x3B, 61: 0x3C, 62: 0x3D, 63: 0x3E,  // F1–F5
        64: 0x3F, 65: 0x40, 66: 0x41, 67: 0x42, 68: 0x43,  // F6–F10
        69: 0x53, 70: 0x47,  // NumLock, ScrollLock
        71: 0x5F, 72: 0x60, 73: 0x61, 74: 0x56,  // KP7 KP8 KP9 KP-
        75: 0x5C, 76: 0x5D, 77: 0x5E, 78: 0x57,  // KP4 KP5 KP6 KP+
        79: 0x59, 80: 0x5A, 81: 0x5B, 82: 0x62, 83: 0x63,  // KP1 KP2 KP3 KP0 KP.
        87: 0x44, 88: 0x45,  // F11 F12
        96: 0x58,  // Keypad Enter
        97: 0xE4,  // RightCtrl
        98: 0x54,  // Keypad /
        100: 0xE6,  // RightAlt
        102: 0x4A, 103: 0x52, 104: 0x4B, 105: 0x50,  // Home Up PageUp Left
        106: 0x4F, 107: 0x4D, 108: 0x51, 109: 0x4E,  // Right End Down PageDown
        110: 0x49, 111: 0x4C,  // Insert Delete
        119: 0x48,  // Pause
        125: 0xE3, 126: 0xE7,  // LeftMeta RightMeta (Super)
        127: 0x65  // Compose / Menu
    ]
}
