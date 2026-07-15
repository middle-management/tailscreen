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

    /// `active` + `pending` share one lock so the enqueue/drain gate is atomic
    /// with `deactivate()`: once a revoke flips `active` false, no already-queued
    /// or late-arriving event is injected — the drain re-checks `active` under
    /// the same lock before taking a batch, closing the revoke TOCTOU where an
    /// event that passed the server gate just before `grant = nil` could still
    /// land afterwards.
    private struct QueueState {
        var active = false
        var pending: [InputEvent] = []
    }
    private let state = OSAllocatedUnfairLock<QueueState>(initialState: QueueState())
    /// What the sharer picked, so the drain can resolve the live capture rect.
    private let selection = OSAllocatedUnfairLock<PickerSelection?>(initialState: nil)

    // Queue-confined pressed-button state so a mouse-move during a drag posts
    // the matching `.leftMouseDragged` / `.rightMouseDragged` instead of a
    // bare `.mouseMoved` (apps track drags off the dragged events). Also lets
    // `deactivate()` synthesize the matching button-up so a revoke mid-drag
    // never leaves a button stuck pressed on the sharer's Mac.
    private var leftDown = false
    private var rightDown = false
    /// Last global point we posted a mouse event at — where a synthesized
    /// button-up lands on revoke. Queue-confined.
    private var lastPoint: CGPoint = .zero

    /// Modifier bits the client is ever allowed to set (matches
    /// `RemoteControlInputView.cgFlags`). A wire `modifiers` value is masked to
    /// this before it reaches `CGEvent.flags`, so a hostile viewer can't set
    /// arbitrary event flags.
    static let allowedModifierMask: UInt64 = {
        let flags: CGEventFlags = [
            .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn
        ]
        return flags.rawValue
    }()

    /// Mask a wire-supplied modifier bitmask to the known-good flag set.
    /// Internal (not private) so it's unit testable.
    static func maskedFlags(_ raw: UInt64) -> UInt64 {
        raw & allowedModifierMask
    }

    /// What the injector *would* post, surfaced to tests. Lets a unit test
    /// assert the gate/coalescing/button-release behavior without a real
    /// `CGEventPost` (which needs Accessibility and would warp the CI cursor).
    enum InjectedAction: Equatable, Sendable {
        enum Side: Sendable { case left, right }
        case mouseDown(Side)
        case mouseUp(Side)
        case mouseMoved
        case drag(Side)
        case scroll
        case keyDown(keyCode: UInt16, flags: UInt64)
        case keyUp(keyCode: UInt16, flags: UInt64)
    }

    /// Test-only sink. When set, injected actions are recorded here and NO real
    /// `CGEvent` is posted or cursor warped, so the injector's logic is testable
    /// headlessly. Fires on the injector's serial queue. Never set in production.
    var onInjectForTesting: ((InjectedAction) -> Void)?

    /// Test-only: block until the serial queue has drained everything enqueued
    /// so far, so a test can assert on `onInjectForTesting` deterministically.
    func drainSyncForTesting() {
        queue.sync {}
    }

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
    /// onto (a mid-share source change) without touching the active/pending
    /// gate. No-op mapping change when no grant is live.
    func setSelection(_ selection: PickerSelection?) {
        self.selection.withLock { $0 = selection }
    }

    /// Arm the injector for a fresh grant: set the mapping, clear any stale
    /// queue, and open the gate. Called from `grantControl`.
    func activate(selection: PickerSelection?) {
        self.selection.withLock { $0 = selection }
        state.withLock { s in
            s.pending.removeAll()
            s.active = true
        }
    }

    /// Seal the injector on revoke/stop: close the gate (so no further event
    /// injects, even one that raced the revoke), drop queued events, clear the
    /// stale mapping, and synthesize a button-up for any button left pressed
    /// mid-drag so revoke never leaves a stuck button on the sharer's Mac.
    func deactivate() {
        state.withLock { s in
            s.active = false
            s.pending.removeAll()
        }
        selection.withLock { $0 = nil }
        queue.async { [weak self] in self?.releaseHeldButtons() }
    }

    /// Enqueue one event for injection. Dropped when the gate is closed. The
    /// event is applied on the serial queue in arrival order.
    func apply(_ event: InputEvent) {
        let accepted = state.withLock { s -> Bool in
            guard s.active else { return false }
            s.pending.append(event)
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        // Take the batch only while still active — a deactivate() that ran
        // between apply() and here leaves active=false, so the batch is
        // dropped and nothing injects post-revoke.
        let batch = state.withLock { s -> [InputEvent] in
            guard s.active else {
                s.pending.removeAll()
                return []
            }
            let snapshot = s.pending
            s.pending.removeAll()
            return snapshot
        }
        guard !batch.isEmpty else { return }
        guard let selection = selection.withLock({ $0 }) else { return }
        for event in RemoteControlPolicy.coalesceMouseMoves(batch) {
            inject(event, selection: selection)
        }
    }

    /// Queue-confined: post a button-up for any button still held, so a revoke
    /// mid-drag doesn't strand a pressed button on the sharer's machine.
    private func releaseHeldButtons() {
        if leftDown {
            leftDown = false
            postMouse(type: .leftMouseUp, at: lastPoint, button: .left)
        }
        if rightDown {
            rightDown = false
            postMouse(type: .rightMouseUp, at: lastPoint, button: .right)
        }
    }

    private func inject(_ event: InputEvent, selection: PickerSelection) {
        switch event {
        case .mouseMove(let nx, let ny):
            guard let point = globalPoint(nx: nx, ny: ny, selection: selection) else { return }
            let type: CGEventType
            let button: CGMouseButton
            if leftDown {
                type = .leftMouseDragged
                button = .left
            } else if rightDown {
                type = .rightMouseDragged
                button = .right
            } else {
                type = .mouseMoved
                button = .left
            }
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
        // Remember where we posted so a revoke can synthesize a button-up here.
        lastPoint = point
        if let hook = onInjectForTesting {
            hook(Self.testAction(for: type))
            return
        }
        // Warp the hardware cursor so it visibly tracks the viewer, then post
        // the event so apps under the point receive it.
        _ = CGWarpMouseCursorPosition(point)
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    private static func testAction(for type: CGEventType) -> InjectedAction {
        switch type {
        case .leftMouseDown: return .mouseDown(.left)
        case .rightMouseDown: return .mouseDown(.right)
        case .leftMouseUp: return .mouseUp(.left)
        case .rightMouseUp: return .mouseUp(.right)
        case .leftMouseDragged: return .drag(.left)
        case .rightMouseDragged: return .drag(.right)
        default: return .mouseMoved
        }
    }

    private func postScroll(deltaX: Double, deltaY: Double) {
        if let hook = onInjectForTesting {
            hook(.scroll)
            return
        }
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
        let masked = Self.maskedFlags(modifiers)
        if let hook = onInjectForTesting {
            hook(keyDown ? .keyDown(keyCode: keyCode, flags: masked) : .keyUp(keyCode: keyCode, flags: masked))
            return
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        // Mask to the known-good flag set so a hostile viewer can't set
        // arbitrary CGEventFlags via the raw wire value.
        event.flags = CGEventFlags(rawValue: masked)
        event.post(tap: .cghidEventTap)
    }
}
