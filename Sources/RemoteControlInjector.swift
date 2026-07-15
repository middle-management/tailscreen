import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Injects viewer input on the sharer's machine via `CGEvent`. Lives in the
/// **main process** — `CGEvent` posting needs the process-level Accessibility
/// TCC grant (distinct from Screen Recording) and has no `replayd` coupling,
/// so unlike SCStream capture it needs no helper isolation.
///
/// Events are applied on one serial queue so per-connection wire order is
/// preserved, and each drain coalesces a burst of consecutive mouse-moves to
/// its last (``RemoteControlPolicy/coalesceMouseMoves``) so a 120 Hz viewer
/// can't flood the injector. Coordinate mapping is re-resolved per event, so a
/// window share that moves is followed automatically.
///
/// Not `@MainActor`: `CGEvent.post` and the coordinate resolvers
/// (`CGDisplayBounds`, `CGWindowListCopyWindowInfo`) are thread-safe, and
/// keeping off the main actor lets the serial queue guarantee ordering without
/// racing MainActor Task scheduling.
final class RemoteControlInjector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.tailscreen.remote-control-injector")
    /// FIFO buffer drained on `queue`. Appended from the caller's thread,
    /// drained (and coalesced) on the serial queue.
    private let pending = OSAllocatedUnfairLock<[InputEvent]>(initialState: [])
    /// What the sharer picked, so the drain can resolve the live capture rect.
    private let selection = OSAllocatedUnfairLock<PickerSelection?>(initialState: nil)

    // Queue-confined pressed-button state so a mouse-move during a drag posts
    // the matching `.leftMouseDragged` / `.rightMouseDragged` instead of a
    // bare `.mouseMoved` (apps track drags off the dragged events).
    private var leftDown = false
    private var rightDown = false

    /// Whether the process currently holds the Accessibility grant `CGEvent`
    /// posting requires. `CGEventPost` no-ops silently when untrusted, so the
    /// grant flow checks this up front and refuses control rather than leaving
    /// a dead grant.
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Trigger the system Accessibility prompt (and add the app to the
    /// Privacy → Accessibility list). Returns the current trust state.
    @discardableResult
    func promptForAccess() -> Bool {
        // `kAXTrustedCheckOptionPrompt` imports inconsistently across SDKs
        // (CFString vs. Unmanaged<CFString>); its value is stable, so build
        // the options dictionary from the literal key to keep this portable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Update the capture geometry the injector maps normalized coordinates
    /// onto. Call at grant time and on any mid-share source change.
    func setSelection(_ selection: PickerSelection?) {
        self.selection.withLock { $0 = selection }
    }

    /// Enqueue one event for injection. Returns immediately; the event is
    /// applied on the serial queue in arrival order.
    func apply(_ event: InputEvent) {
        pending.withLock { $0.append(event) }
        queue.async { [weak self] in self?.drain() }
    }

    /// Drop any queued events without applying them — used when a grant is
    /// revoked so in-flight input doesn't land after control ends.
    func reset() {
        pending.withLock { $0.removeAll() }
        queue.async { [weak self] in
            self?.leftDown = false
            self?.rightDown = false
        }
    }

    private func drain() {
        let batch = pending.withLock { current -> [InputEvent] in
            let snapshot = current
            current.removeAll()
            return snapshot
        }
        guard !batch.isEmpty else { return }
        guard let selection = selection.withLock({ $0 }) else { return }
        for event in RemoteControlPolicy.coalesceMouseMoves(batch) {
            inject(event, selection: selection)
        }
    }

    private func inject(_ event: InputEvent, selection: PickerSelection) {
        switch event {
        case .mouseMove(let nx, let ny):
            guard let point = globalPoint(nx: nx, ny: ny, selection: selection) else { return }
            let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
            let button: CGMouseButton = rightDown ? .right : .left
            postMouse(type: type, at: point, button: button)
        case .mouseDown(let nx, let ny, let mouseButton):
            guard let point = globalPoint(nx: nx, ny: ny, selection: selection) else { return }
            if mouseButton == .right {
                rightDown = true
                postMouse(type: .rightMouseDown, at: point, button: .right)
            } else {
                leftDown = true
                postMouse(type: .leftMouseDown, at: point, button: .left)
            }
        case .mouseUp(let nx, let ny, let mouseButton):
            guard let point = globalPoint(nx: nx, ny: ny, selection: selection) else { return }
            if mouseButton == .right {
                rightDown = false
                postMouse(type: .rightMouseUp, at: point, button: .right)
            } else {
                leftDown = false
                postMouse(type: .leftMouseUp, at: point, button: .left)
            }
        case .scroll(_, _, let deltaX, let deltaY):
            postScroll(deltaX: deltaX, deltaY: deltaY)
        case .keyDown(let keyCode, let modifiers):
            postKey(keyCode: keyCode, modifiers: modifiers, keyDown: true)
        case .keyUp(let keyCode, let modifiers):
            postKey(keyCode: keyCode, modifiers: modifiers, keyDown: false)
        }
    }

    private func globalPoint(nx: Double, ny: Double, selection: PickerSelection) -> CGPoint? {
        guard let rect = RemoteControlMapping.captureRect(for: selection) else { return nil }
        return RemoteControlMapping.globalPoint(nx: nx, ny: ny, captureRect: rect)
    }

    private func postMouse(type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        // Warp the hardware cursor so it visibly tracks the viewer, then post
        // the event so apps under the point receive it.
        CGWarpMouseCursorPosition(point)
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(deltaX: Double, deltaY: Double) {
        // Wire deltas are viewer-controlled: guard against NaN / infinity /
        // out-of-range before the Int conversion (which would otherwise trap).
        let wheel1 = Self.clampToInt32(deltaY)
        let wheel2 = Self.clampToInt32(deltaX)
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: wheel1, wheel2: wheel2,
                wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Safe Double → Int32 for wire-supplied scroll deltas: NaN/±∞ → 0, and
    /// out-of-range values saturate rather than trapping.
    private static func clampToInt32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int32.max) { return Int32.max }
        if rounded <= Double(Int32.min) { return Int32.min }
        return Int32(rounded)
    }

    private func postKey(keyCode: UInt16, modifiers: UInt64, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.flags = CGEventFlags(rawValue: modifiers)
        event.post(tap: .cghidEventTap)
    }
}
