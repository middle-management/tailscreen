import AppKit
import Carbon.HIToolbox

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

    /// `keyCode` is a Carbon virtual key (e.g. `kVK_ANSI_M = 46`).
    /// `modifierFlags` is a Carbon mask (`controlKey`, `optionKey`,
    /// `cmdKey`, `shiftKey` from `Carbon.HIToolbox.Events`).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var hotKeyID = EventHotKeyID(signature: OSType(0x54534E48), id: 1) // 'TSNH'
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
            print("GlobalHotkey: RegisterEventHotKey failed (OSStatus=\(regStatus))")
            return
        }
        self.hotKeyRef = ref

        // Install once per process; the handler dispatches by the
        // hotKeyID's `id` field, so multiple GlobalHotkey instances
        // would each need their own ID. We currently only register
        // one, so this is fine.
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
