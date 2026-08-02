import AppKit
import Carbon.HIToolbox
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

// MARK: - Logger

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Hotkey] \(message)")
    }
}
