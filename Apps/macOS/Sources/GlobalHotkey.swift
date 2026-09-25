import AppKit
import Carbon.HIToolbox
import SwiftUI
import TailscaleKit

/// Process-wide hotkey via Carbon `RegisterEventHotKey`. SwiftUI's
/// `.keyboardShortcut` only fires while the app's window is key, and
/// MenuBarExtra apps spend most of their time without one; Carbon hotkeys are
/// the supported sandbox-friendly system-wide alternative (no Accessibility
/// permission needed).
///
/// Not `@MainActor`, so `deinit` can clean up the Carbon handles without
/// tripping Swift 6's non-Sendable deinit check — Carbon's handlers already
/// fire on the main thread, and the action callback hops to `@MainActor` explicitly.
final class GlobalHotkey: @unchecked Sendable {
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Carbon dispatches a hotkey-pressed event to every installed handler
    /// most-recent-first, stopping at the first `noErr` — without filtering
    /// on this id, the last-registered handler swallows every hotkey.
    private let hotKeyIDValue: UInt32
    /// Signature shared by all Tailscreen hotkeys ('TSNH').
    static let signature = OSType(0x54534E48)

    /// `RegisterEventHotKey` refuses a chord another app already holds via a
    /// silent return code — the object still constructs, the key just never
    /// fires. Callers that advertise a shortcut should check this.
    var isRegistered: Bool { hotKeyRef != nil }

    /// Pure dispatch predicate, extracted so id-filtering is unit testable
    /// without pressing real keys.
    static func handlerShouldFire(
        eventSignature: OSType, eventID: UInt32, registeredSignature: OSType, registeredID: UInt32
    ) -> Bool {
        eventSignature == registeredSignature && eventID == registeredID
    }

    /// `id` distinguishes concurrently-registered hotkeys — `RegisterEventHotKey`
    /// needs a unique `(signature, id)` per registration (mic toggle uses 1,
    /// panic-revoke uses 2).
    init(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.hotKeyIDValue = id
        register(keyCode: keyCode, modifiers: modifiers, id: id)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Clear of live registrations (mic toggle 1, panic revoke 2).
    static let probeHotkeyID: UInt32 = 0xFFFF

    /// Transiently registers the chord and reports whether the system granted
    /// it; the probe's `deinit` unregisters immediately, so nothing is claimed.
    static func probeAvailability(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let probe = GlobalHotkey(keyCode: keyCode, modifiers: modifiers, id: probeHotkeyID) {}
        return probe.isRegistered
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)  // 'TSNH'
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard regStatus == noErr, let ref else {
            // `eventHotKeyExistsErr` (-9878): another app already owns this
            // combo, first registration wins. Hence `isRegistered` is exposed,
            // not just logged.
            TSLogger().log(
                "GlobalHotkey: RegisterEventHotKey failed (OSStatus=\(regStatus))"
                    + " — the combo is probably owned by another app")
            return
        }
        self.hotKeyRef = ref

        // Must filter on `EventHotKeyID` and return `eventNotHandledErr` on a
        // mismatch, or this handler swallows other hotkeys' events.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr else { return status }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                guard
                    GlobalHotkey.handlerShouldFire(
                        eventSignature: id.signature, eventID: id.id,
                        registeredSignature: GlobalHotkey.signature, registeredID: me.hotKeyIDValue)
                else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in me.action() }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &handler
        )
        self.handlerRef = handler
    }
}

extension UInt32 {
    /// ⌃⌥, avoiding ⌘ collisions with system-wide bindings (Cmd+M minimizes
    /// the front window).
    static let controlOptionMask = UInt32(controlKey | optionKey)
}

// MARK: - User-configurable chord

/// Carbon virtual keycode + modifier mask, stored raw since that's exactly
/// what `RegisterEventHotKey` consumes.
///
/// Display goes the other way through audited tables rather than a fourth
/// hand-written keycode list: keycode -> HID usage (`MacKeyCodeMapping`) ->
/// `ShortcutKey` (inverting `ShortcutKey.hidUsage`) -> `ShortcutChord.display(.appleSymbols)`.
/// A key outside that vocabulary (F-keys, arrows, keypad) yields `nil`
/// everywhere; the UI hides the chord and the recorder refuses to store one.
struct HotkeyChord: Codable, Equatable, Sendable {
    /// Same space as `NSEvent.keyCode`, widened to `UInt32`.
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultMicToggle = HotkeyChord(
        keyCode: UInt32(kVK_ANSI_M), modifiers: .controlOptionMask)
    static let defaultRevokeControl = HotkeyChord(
        keyCode: UInt32(kVK_ANSI_Period), modifiers: .controlOptionMask)

    /// Stricter than `GlobalHotkeyMapping`'s no-modifiers rule: a shift-only
    /// chord is just typing, and a bare key registered system-wide steals
    /// from every other app.
    var hasRequiredModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    var isValidUserChord: Bool {
        hasRequiredModifier && shortcutKey != nil
    }

    /// The chord's key in the cross-platform `ShortcutCatalog` vocabulary, or
    /// nil when that vocabulary doesn't cover it.
    var shortcutKey: ShortcutKey? {
        guard let code = UInt16(exactly: keyCode),
            let usage = MacKeyCodeMapping.hidUsage(forMacKeyCode: code)
        else { return nil }
        return Self.shortcutKeyByHIDUsage[usage]
    }

    /// ⌘ maps onto `.primary`, which `display(.appleSymbols)` renders as ⌘.
    var displayChord: ShortcutChord? {
        guard let key = shortcutKey else { return nil }
        var mods: ShortcutModifiers = []
        if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mods.insert(.primary) }
        return ShortcutChord(key, mods)
    }

    /// nil for an unmappable key — callers hide the chord rather than print a
    /// wrong one.
    var displayString: String? {
        displayChord?.display(.appleSymbols)
    }

    /// nil when the key can't map, so the menu item keeps an empty equivalent
    /// rather than advertising a chord that won't fire.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        guard let shortcutKey else { return nil }
        let key: String
        switch shortcutKey {
        case .character(let raw):
            // Lowercase, or AppKit reads an uppercase equivalent as "shift
            // required" and silently adds ⇧.
            key = raw.lowercased()
        case .delete:
            key = "\u{8}"
        case .escape:
            key = "\u{1b}"
        }
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return (key, mask)
    }

    /// Same nil contract as `menuKeyEquivalent`.
    var swiftUIShortcut: KeyboardShortcut? {
        guard let shortcutKey else { return nil }
        let key: KeyEquivalent
        switch shortcutKey {
        case .character(let raw):
            guard let character = raw.lowercased().first else { return nil }
            key = KeyEquivalent(character)
        case .delete:
            key = .delete
        case .escape:
            key = .escape
        }
        // Qualified: Carbon's HIToolbox typedefs its own `EventModifiers` too.
        var mods: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mods.insert(.command) }
        return KeyboardShortcut(key, modifiers: mods)
    }

    /// AppKit -> Carbon modifier translation for the shortcut recorder.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Inverse of `ShortcutKey.hidUsage`, derived rather than hand-written.
    /// Space is deliberately left out — it renders as an invisible glyph.
    private static let shortcutKeyByHIDUsage: [UInt16: ShortcutKey] = {
        var candidates: [ShortcutKey] = [.escape, .delete]
        let characters = "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;'`,./"
        for character in characters {
            candidates.append(.character(String(character)))
        }
        var out: [UInt16: ShortcutKey] = [:]
        for key in candidates {
            guard let usage = key.hidUsage else { continue }
            out[usage] = key
        }
        return out
    }()
}

/// Persisted hotkey chords. Plain `UserDefaults` (like `ViewerApprovalPreference`)
/// so non-SwiftUI call sites can read without `@AppStorage`. A missing,
/// corrupt, or invalid blob degrades to the shipped chord.
enum HotkeyChordStore {
    static let micKey = "micHotkeyChord"
    static let revokeKey = "revokeControlHotkeyChord"

    static func loadMic(defaults: UserDefaults = .standard) -> HotkeyChord {
        load(key: micKey, fallback: .defaultMicToggle, defaults: defaults)
    }

    static func loadRevoke(defaults: UserDefaults = .standard) -> HotkeyChord {
        load(key: revokeKey, fallback: .defaultRevokeControl, defaults: defaults)
    }

    static func saveMic(_ chord: HotkeyChord, defaults: UserDefaults = .standard) {
        save(chord, key: micKey, defaults: defaults)
    }

    static func saveRevoke(_ chord: HotkeyChord, defaults: UserDefaults = .standard) {
        save(chord, key: revokeKey, defaults: defaults)
    }

    private static func load(
        key: String, fallback: HotkeyChord, defaults: UserDefaults
    ) -> HotkeyChord {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(HotkeyChord.self, from: data),
            decoded.isValidUserChord
        else { return fallback }
        return decoded
    }

    private static func save(_ chord: HotkeyChord, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(chord) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Logger

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Hotkey] \(message)")
    }
}
