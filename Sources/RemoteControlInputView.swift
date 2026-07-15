import AppKit
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

    private var trackingArea: NSTrackingArea?
    /// Latest raw `CGEventFlags` modifier bitmask (from `flagsChanged`),
    /// folded into key events so the sharer reproduces held modifiers.
    private var currentModifiers: UInt64 = 0
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

    private func emitMove(_ event: NSEvent) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs &- lastMoveEmitNs >= Self.moveEmitMinIntervalNs else { return }
        lastMoveEmitNs = nowNs
        let point = normalized(event)
        onEvent?(.mouseMove(x: Double(point.x), y: Double(point.y)))
    }

    override func mouseDown(with event: NSEvent) {
        let point = normalized(event)
        onEvent?(.mouseDown(x: Double(point.x), y: Double(point.y), button: .left))
    }

    override func mouseUp(with event: NSEvent) {
        let point = normalized(event)
        onEvent?(.mouseUp(x: Double(point.x), y: Double(point.y), button: .left))
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = normalized(event)
        onEvent?(.mouseDown(x: Double(point.x), y: Double(point.y), button: .right))
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = normalized(event)
        onEvent?(.mouseUp(x: Double(point.x), y: Double(point.y), button: .right))
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
                deltaY: Double(event.scrollingDeltaY) * unit))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        onEvent?(.keyDown(keyCode: event.keyCode, modifiers: currentModifiers))
    }

    override func keyUp(with event: NSEvent) {
        onEvent?(.keyUp(keyCode: event.keyCode, modifiers: currentModifiers))
    }

    override func flagsChanged(with event: NSEvent) {
        currentModifiers = Self.cgFlags(from: event.modifierFlags)
    }

    /// Map AppKit modifier flags to a raw `CGEventFlags` bitmask for the wire.
    /// Internal + `nonisolated` (pure — no main-actor state) so the mapping is
    /// unit testable off the main actor.
    nonisolated static func cgFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var out: CGEventFlags = []
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.capsLock) { out.insert(.maskAlphaShift) }
        if flags.contains(.function) { out.insert(.maskSecondaryFn) }
        return out.rawValue
    }
}
