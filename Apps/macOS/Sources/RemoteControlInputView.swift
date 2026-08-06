import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Transparent capture layer inside the viewer window that, while remote
/// control is active, turns local pointer/keyboard events into normalized
/// ``InputEvent``s for the sharer. Sits above the annotation overlay and is
/// framed to the same aspect-fit video rect (by `AspectFitHostView.layout`),
/// so normalizing within its own bounds yields `[0, 1]` video coordinates
/// directly — the exact convention ``Annotation`` uses.
///
/// Hidden (and inert) unless capturing, so annotation drawing and content
/// zoom/pan keep working when control mode is off. The two are mutually
/// exclusive in the UI.
@MainActor
final class RemoteControlInputView: NSView {
    /// Emits each captured input event. AppState forwards it to the client's
    /// TCP back-channel.
    var onEvent: ((InputEvent) -> Void)?

    /// Fires when the user presses the ⌃⌥. release chord while input capture
    /// is live. Every other keystroke is forwarded to the sharer; this one is
    /// the viewer's exit hatch and must never be — a forwarded chord would be
    /// replayed on the sharer instead of releasing the grant, stranding a
    /// keyboard-only user in capture mode.
    var onReleaseChord: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    /// ~90 Hz throttle on move emission. Down/up/scroll/key are never dropped.
    private var lastMoveEmitNs: UInt64 = 0
    private static let moveEmitMinIntervalNs: UInt64 = 11_000_000

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // Flipped so top-left origin matches the normalized video space.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Turn capture on/off. When on, the view shows (intercepting events),
    /// enables window mouse-moved delivery, and grabs first responder.
    func setCapturing(_ capturing: Bool) {
        isHidden = !capturing
        guard capturing, let window else { return }
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        return CGPoint(
            x: min(max(point.x / width, 0), 1),
            y: min(max(point.y / height, 0), 1))
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) { emitMove(event) }
    override func mouseDragged(with event: NSEvent) { emitMove(event) }
    override func rightMouseDragged(with event: NSEvent) { emitMove(event) }
    override func otherMouseDragged(with event: NSEvent) { emitMove(event) }

    private func emitMove(_ event: NSEvent) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs &- lastMoveEmitNs >= Self.moveEmitMinIntervalNs else { return }
        lastMoveEmitNs = nowNs
        let point = normalized(event)
        onEvent?(.mouseMove(x: Double(point.x), y: Double(point.y)))
    }

    override func mouseDown(with event: NSEvent) {
        emitButton(event, down: true, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        emitButton(event, down: false, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        emitButton(event, down: true, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        emitButton(event, down: false, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        // buttonNumber 2 is the middle button; higher buttons (back/forward
        // etc.) have no wire representation and are swallowed.
        guard event.buttonNumber == 2 else { return }
        emitButton(event, down: true, button: .middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        emitButton(event, down: false, button: .middle)
    }

    private func emitButton(_ event: NSEvent, down: Bool, button: InputEvent.MouseButton) {
        let point = normalized(event)
        let x = Double(point.x)
        let y = Double(point.y)
        // Each NSEvent carries the modifier state at event time — never a
        // cached snapshot, which goes stale whenever a modifier is released
        // while this view is hidden (revoke) or the app inactive (⌘-Tab)
        // and would then inject a plain click as a modified one.
        let modifiers = Self.keyModifiers(from: event.modifierFlags)
        if down {
            onEvent?(.mouseDown(x: x, y: y, button: button, modifiers: modifiers))
        } else {
            onEvent?(.mouseUp(x: x, y: y, button: button, modifiers: modifiers))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = normalized(event)
        // Precise (trackpad) deltas are in points; scale down so a wire "line"
        // count stays sensible. Classic wheels already report line units.
        let unit: Double = event.hasPreciseScrollingDeltas ? 0.1 : 1
        onEvent?(
            .scroll(
                x: Double(point.x),
                y: Double(point.y),
                deltaX: Double(event.scrollingDeltaX) * unit,
                deltaY: Double(event.scrollingDeltaY) * unit,
                modifiers: Self.keyModifiers(from: event.modifierFlags)))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // ⌃⌥. — Release Remote Control (mirrors the File-menu item).
        // Intercepted before forwarding; see `onReleaseChord`.
        if event.keyCode == UInt16(kVK_ANSI_Period),
            event.modifierFlags.intersection([.shift, .control, .option, .command]) == [.control, .option]
        {
            onReleaseChord?()
            return
        }
        // Keys outside the HID table have no wire representation — drop
        // rather than guess (see MacKeyCodeMapping).
        guard let usage = MacKeyCodeMapping.hidUsage(forMacKeyCode: event.keyCode) else { return }
        onEvent?(.keyDown(key: usage, modifiers: Self.keyModifiers(from: event.modifierFlags)))
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = MacKeyCodeMapping.hidUsage(forMacKeyCode: event.keyCode) else { return }
        onEvent?(.keyUp(key: usage, modifiers: Self.keyModifiers(from: event.modifierFlags)))
    }

    /// Map AppKit modifier flags to the wire's neutral ``KeyModifiers`` set.
    /// Internal + `nonisolated` (pure — no main-actor state) so the mapping is
    /// unit testable off the main actor. `.function` (fn) has no neutral bit —
    /// see ``KeyModifiers``.
    nonisolated static func keyModifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var out: KeyModifiers = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option) { out.insert(.alt) }
        if flags.contains(.command) { out.insert(.meta) }
        if flags.contains(.capsLock) { out.insert(.capsLock) }
        return out
    }
}
