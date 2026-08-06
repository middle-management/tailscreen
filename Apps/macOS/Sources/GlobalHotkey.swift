import AppKit
import Carbon.HIToolbox
import SwiftUI
import TailscaleKit

/// Process-wide hotkey via Carbon `RegisterEventHotKey`. SwiftUI's
/// `.keyboardShortcut` only fires while the app's window is key, and
/// MenuBarExtra apps spend most of their time without a key window.
/// Carbon hotkeys are the supported way to register a system-wide
/// shortcut from a sandbox-friendly menubar app — no Accessibility
/// permission required.
///
/// Not `@MainActor` so that `deinit` can clean up the Carbon handles
/// without tripping Swift 6's non-Sendable deinit access check —
/// Carbon's event handlers fire on the main thread already, and the
/// action callback hops to `@MainActor` explicitly.
final class GlobalHotkey: @unchecked Sendable {
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// This hotkey's registered id. The Carbon event handler compares the
    /// fired event's `EventHotKeyID.id` against this and only runs `action`
    /// on a match — every `GlobalHotkey` installs its own handler on the
    /// shared application event target, and Carbon dispatches a hotkey-pressed
    /// event to each installed handler most-recent-first, stopping at the
    /// first `noErr`. Without this filter the last-registered handler would
    /// swallow *every* hotkey (returning `noErr` unconditionally) and starve
    /// the others — e.g. the revoke hotkey killing the mic toggle.
    private let hotKeyIDValue: UInt32
    /// Signature shared by all Tailscreen hotkeys ('TSNH').
    static let signature = OSType(0x54534E48)

    /// Whether the system actually gave us this combo.
    ///
    /// `RegisterEventHotKey` refuses a chord another app already holds, and
    /// the refusal is a return code — the object constructs fine either way
    /// and the key silently does nothing. Callers that *advertise* a shortcut
    /// (the menu key equivalent, the cheat sheet, a future Settings pane)
    /// should consult this so the app can admit the shortcut is unavailable
    /// instead of printing a chord that will never fire.
    var isRegistered: Bool { hotKeyRef != nil }

    /// Pure dispatch predicate: should a handler registered for
    /// `registeredSignature`/`registeredID` run for a fired event carrying
    /// `eventSignature`/`eventID`? Extracted so the id-filtering is unit
    /// testable without pressing real keys.
    static func handlerShouldFire(
        eventSignature: OSType, eventID: UInt32, registeredSignature: OSType, registeredID: UInt32
    ) -> Bool {
        eventSignature == registeredSignature && eventID == registeredID
    }

    /// `keyCode` is a Carbon virtual key (e.g. `kVK_ANSI_M = 46`).
    /// `modifierFlags` is a Carbon mask (`controlKey`, `optionKey`,
    /// `cmdKey`, `shiftKey` from `Carbon.HIToolbox.Events`). `id`
    /// distinguishes concurrently-registered hotkeys — `RegisterEventHotKey`
    /// needs a unique `(signature, id)` per registration, so each live
    /// `GlobalHotkey` instance must pass a distinct value (the mic toggle
    /// uses 1, the remote-control panic-revoke uses 2). The installed handler
    /// filters on this id so one hotkey's handler never swallows another's.
    init(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.hotKeyIDValue = id
        register(keyCode: keyCode, modifiers: modifiers, id: id)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Hotkey id used by `probeAvailability` — well clear of the live
    /// registrations (mic toggle 1, panic revoke 2) so a probe can never
    /// collide with a real `(signature, id)` pair.
    static let probeHotkeyID: UInt32 = 0xFFFF

    /// One-shot availability probe: transiently register the chord and
    /// report whether the system granted it. The probe instance deallocates
    /// on return, and its `deinit` unregisters — so a granted chord is held
    /// for microseconds, never claimed. Used by Settings to warn about a
    /// recorded chord another app owns *before* the moment it matters (the
    /// panic-revoke hotkey only truly registers while a grant is live).
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
            // `eventHotKeyExistsErr` (-9878) is the one that actually happens:
            // another app already owns this combo system-wide, first
            // registration wins, and ours is simply refused. The user then
            // presses the key forever and nothing happens — which is why
            // `isRegistered` is exposed rather than only logged. A shortcut
            // the app advertises but did not get is worse than one it never
            // claimed, because the user has no reason to doubt it.
            TSLogger().log(
                "GlobalHotkey: RegisterEventHotKey failed (OSStatus=\(regStatus))"
                    + " — the combo is probably owned by another app")
            return
        }
        self.hotKeyRef = ref

        // Each instance installs its own handler bound to its own `self`.
        // Carbon dispatches a hotkey-pressed event to every installed handler
        // (most-recent-first, stopping at the first `noErr`), so the handler
        // MUST filter on the fired event's `EventHotKeyID` and return
        // `eventNotHandledErr` on a mismatch — otherwise it would swallow
        // other hotkeys' events (e.g. the revoke handler eating ⌃⌥M).
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
                // Only handle the hotkey this instance registered; let Carbon
                // fall through to the next handler otherwise.
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
    /// ⌃⌥ — Ctrl+Option, the default Tailscreen mic-toggle modifiers.
    /// Avoids ⌘ collisions with system-wide bindings (Cmd+M minimizes
    /// the front window).
    static let controlOptionMask = UInt32(controlKey | optionKey)
}

// MARK: - User-configurable chord

/// A user-configurable global-hotkey chord: Carbon virtual keycode plus
/// Carbon modifier mask — exactly the pair `RegisterEventHotKey` (and so
/// `GlobalHotkey.init`) consumes, which is why it is stored raw rather
/// than re-derived from a display string.
///
/// Display goes the other way, through the tables the repo already audits
/// instead of a fourth hand-written keycode list: keycode → HID usage via
/// `MacKeyCodeMapping` (the remote-control wire table, pinned by
/// `MacKeyCodeMappingTests`), HID usage → `ShortcutKey` by inverting
/// `ShortcutKey.hidUsage` (the cross-platform hotkey vocabulary), then
/// `ShortcutChord.display(.appleSymbols)` for the "⌃⌥M" spelling the menu
/// bar and cheat sheet use. A key outside that vocabulary (F-keys, arrows,
/// keypad) yields `nil` everywhere — the UI hides the chord rather than
/// printing one it can't spell, and the recorder refuses to store one.
struct HotkeyChord: Codable, Equatable, Sendable {
    /// Carbon virtual keycode (`kVK_*`) — the same space `NSEvent.keyCode`
    /// reports, widened to the `UInt32` `RegisterEventHotKey` takes.
    var keyCode: UInt32
    /// Carbon modifier mask (`controlKey` / `optionKey` / `shiftKey` /
    /// `cmdKey` from `Carbon.HIToolbox.Events`).
    var modifiers: UInt32

    /// ⌃⌥M — the shipped mic-toggle default (see `controlOptionMask`).
    static let defaultMicToggle = HotkeyChord(
        keyCode: UInt32(kVK_ANSI_M), modifiers: .controlOptionMask)
    /// ⌃⌥. — the shipped panic-revoke default.
    static let defaultRevokeControl = HotkeyChord(
        keyCode: UInt32(kVK_ANSI_Period), modifiers: .controlOptionMask)

    /// Whether the chord carries at least one of ⌃⌥⌘. Stricter than
    /// `GlobalHotkeyMapping`'s no-modifiers rule on purpose: a shift-only
    /// chord is just typing, and a bare key registered system-wide is
    /// stolen from every other app on the machine.
    var hasRequiredModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// What the recorder (and the persisted-blob validator) accepts: a
    /// required modifier plus a key the display vocabulary can spell.
    var isValidUserChord: Bool {
        hasRequiredModifier && shortcutKey != nil
    }

    /// The chord's key in the cross-platform `ShortcutCatalog` vocabulary,
    /// or nil when it names a key that vocabulary doesn't cover.
    var shortcutKey: ShortcutKey? {
        guard let code = UInt16(exactly: keyCode),
            let usage = MacKeyCodeMapping.hidUsage(forMacKeyCode: code)
        else { return nil }
        return Self.shortcutKeyByHIDUsage[usage]
    }

    /// The chord in `ShortcutCatalog` terms, for display. ⌘ maps onto
    /// `.primary` — on this platform that role *is* ⌘, and it's what
    /// `display(.appleSymbols)` renders as the ⌘ glyph.
    var displayChord: ShortcutChord? {
        guard let key = shortcutKey else { return nil }
        var mods: ShortcutModifiers = []
        if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mods.insert(.primary) }
        return ShortcutChord(key, mods)
    }

    /// "⌃⌥M"-style spelling (Apple glyph order), or nil for an unmappable
    /// key — callers hide the chord rather than print a wrong one.
    var displayString: String? {
        displayChord?.display(.appleSymbols)
    }

    /// The chord as an `NSMenuItem` key equivalent (character + AppKit
    /// modifier mask), or nil when the key can't map — the menu item then
    /// keeps an empty equivalent instead of advertising a chord that won't
    /// fire. The special-key characters follow the menu conventions already
    /// AppKit expects ("\u{8}" renders as ⌫ in a key equivalent).
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        guard let shortcutKey else { return nil }
        let key: String
        switch shortcutKey {
        case .character(let raw):
            // Lowercase: an uppercase key equivalent means "shift required"
            // to AppKit, which would silently add ⇧ to the printed chord.
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

    /// The chord as a SwiftUI `KeyboardShortcut`, for the `Commands`-built
    /// menu items that mirror the global hotkeys. Same nil contract as
    /// `menuKeyEquivalent`: an unmappable key yields no shortcut rather
    /// than a chord that won't fire — `.keyboardShortcut(_:)` takes the
    /// optional directly, so the item simply loses its printed chord.
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
        var mods: EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mods.insert(.command) }
        return KeyboardShortcut(key, modifiers: mods)
    }

    /// AppKit → Carbon modifier translation for the shortcut recorder
    /// (`NSEvent.modifierFlags` is what a keyDown carries).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Inverse of `ShortcutKey.hidUsage`, derived from it rather than
    /// hand-written so it inherits that table's audited constants: every
    /// candidate the vocabulary can name is run through the forward map
    /// once. Space is deliberately left out — it maps fine but renders as
    /// an invisible glyph in a chord ("⌃⌥ "), so the recorder refuses it.
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

/// Persisted hotkey chords. Mirrors `ViewerApprovalDefaults` — plain
/// `UserDefaults` so non-SwiftUI call sites (`AppState.init`'s
/// stored-property initialisers) can read the saved
/// value without `@AppStorage`. A missing, corrupt, or invalid blob (no
/// required modifier, unmappable key — e.g. hand-edited defaults) degrades
/// to the shipped chord rather than to a hotkey the UI can't spell.
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
