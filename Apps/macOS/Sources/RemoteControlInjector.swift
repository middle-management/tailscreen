import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Injects viewer input via `CGEvent`. Lives in the **main process**:
/// `CGEvent` posting needs the process-level Accessibility TCC grant (not
/// Screen Recording) and has no `replayd` coupling, so unlike SCStream it
/// needs no helper isolation.
///
/// Applied on one serial queue to preserve wire order; each drain coalesces
/// consecutive mouse-moves (``RemoteControlPolicy/coalesceMouseMoves``) so a
/// 120Hz viewer can't flood the injector. Coordinate mapping is re-resolved
/// per event, so a moved window share is followed automatically.
///
/// Not `@MainActor`: `CGEvent.post` and the coordinate resolvers are
/// thread-safe, and staying off the main actor lets the serial queue
/// guarantee ordering without racing MainActor Task scheduling.
final class RemoteControlInjector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.tailscreen.remote-control-injector")

    /// `active`/`pending` share one lock so the gate is atomic with
    /// `deactivate()`: the drain re-checks `active` before taking a batch,
    /// closing the TOCTOU where an event passing the server gate just before
    /// revoke could still land.
    private struct QueueState {
        var active = false
        var pending: [InputEvent] = []
    }
    private let state = OSAllocatedUnfairLock<QueueState>(initialState: QueueState())
    /// What the sharer picked, so the drain can resolve the live capture rect.
    private let selection = OSAllocatedUnfairLock<PickerSelection?>(initialState: nil)

    // Queue-confined pressed-button state so a mouse-move during a drag posts
    // the matching `.*Dragged` type instead of a bare `.mouseMoved`, and
    // `deactivate()` can synthesize the matching button-up.
    private var leftDown = false
    private var rightDown = false
    private var middleDown = false
    /// Where a synthesized button-up lands on revoke. Queue-confined.
    private var lastPoint: CGPoint = .zero
    /// Cleared on revoke so one controller's half-line doesn't ride into the
    /// next controller's first scroll. See ``MacPointerMapping``.
    private var scrollAccumulator = MacPointerMapping.ScrollLineAccumulator()

    /// Constructive: only the five known bits produce flags, so a hostile
    /// viewer can't set flags outside this set. Internal so it's unit testable.
    static func eventFlags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var out: CGEventFlags = []
        if modifiers.contains(.shift) { out.insert(.maskShift) }
        if modifiers.contains(.control) { out.insert(.maskControl) }
        if modifiers.contains(.alt) { out.insert(.maskAlternate) }
        if modifiers.contains(.meta) { out.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { out.insert(.maskAlphaShift) }
        return out
    }

    /// What the injector *would* post, surfaced to tests without a real
    /// `CGEventPost` (needs Accessibility, would warp the CI cursor).
    enum InjectedAction: Equatable, Sendable {
        enum Side: Sendable { case left, right, middle }
        case mouseDown(Side, flags: UInt64)
        case mouseUp(Side, flags: UInt64)
        case mouseMoved
        case drag(Side)
        /// `wheelY`/`wheelX` are the accumulated whole-line counts handed to
        /// `CGEvent`, not the raw wire deltas.
        case scroll(wheelY: Int32, wheelX: Int32, flags: UInt64)
        /// `keyCode` is the translated mac virtual keycode.
        case keyDown(keyCode: UInt16, flags: UInt64)
        case keyUp(keyCode: UInt16, flags: UInt64)
    }

    /// Never set in production. Fires on the injector's serial queue.
    var onInjectForTesting: ((InjectedAction) -> Void)?

    /// Test-only: blocks until everything enqueued so far has drained.
    func drainSyncForTesting() {
        queue.sync {}
    }

    /// `CGEventPost` no-ops silently when untrusted, so the grant flow checks
    /// this up front rather than leaving a dead grant.
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func promptForAccess() -> Bool {
        // `kAXTrustedCheckOptionPrompt` imports inconsistently across SDKs
        // (CFString vs. Unmanaged<CFString>); the literal key is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Mid-share source change, without touching the active/pending gate.
    func setSelection(_ selection: PickerSelection?) {
        self.selection.withLock { $0 = selection }
    }

    /// Sets the mapping, clears any stale queue, and opens the gate. Called
    /// from `grantControl`.
    func activate(selection: PickerSelection?) {
        self.selection.withLock { $0 = selection }
        state.withLock { s in
            s.pending.removeAll()
            s.active = true
        }
    }

    /// Closes the gate, drops queued events, clears the mapping, and
    /// synthesizes a button-up for any button left pressed mid-drag.
    func deactivate() {
        state.withLock { s in
            s.active = false
            s.pending.removeAll()
        }
        selection.withLock { $0 = nil }
        queue.async { [weak self] in self?.releaseHeldButtons() }
    }

    /// Dropped when the gate is closed; applied on the serial queue in
    /// arrival order.
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
        // Take the batch only while still active, or a deactivate() racing
        // apply() would still inject post-revoke.
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

    private func releaseHeldButtons() {
        scrollAccumulator.reset()
        if leftDown {
            leftDown = false
            postMouse(type: .leftMouseUp, at: lastPoint, button: .left)
        }
        if rightDown {
            rightDown = false
            postMouse(type: .rightMouseUp, at: lastPoint, button: .right)
        }
        if middleDown {
            middleDown = false
            postMouse(type: .otherMouseUp, at: lastPoint, button: .center)
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
            } else if middleDown {
                type = .otherMouseDragged
                button = .center
            } else {
                type = .mouseMoved
                button = .left
            }
            postMouse(type: type, at: point, button: button)
        case .mouseDown(let nx, let ny, let mouseButton, let modifiers):
            guard let point = globalPoint(nx: nx, ny: ny, selection: selection) else { return }
            switch mouseButton {
            case .left:
                leftDown = true
                postMouse(type: .leftMouseDown, at: point, button: .left, modifiers: modifiers)
            case .right:
                rightDown = true
                postMouse(type: .rightMouseDown, at: point, button: .right, modifiers: modifiers)
            case .middle:
                middleDown = true
                postMouse(type: .otherMouseDown, at: point, button: .center, modifiers: modifiers)
            }
        case .mouseUp(let nx, let ny, let mouseButton, let modifiers):
            guard let point = globalPoint(nx: nx, ny: ny, selection: selection) else { return }
            switch mouseButton {
            case .left:
                leftDown = false
                postMouse(type: .leftMouseUp, at: point, button: .left, modifiers: modifiers)
            case .right:
                rightDown = false
                postMouse(type: .rightMouseUp, at: point, button: .right, modifiers: modifiers)
            case .middle:
                middleDown = false
                postMouse(type: .otherMouseUp, at: point, button: .center, modifiers: modifiers)
            }
        case .scroll(_, _, let deltaX, let deltaY, let modifiers):
            postScroll(deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
        case .keyDown(let key, let modifiers):
            postKey(hidUsage: key, modifiers: modifiers, keyDown: true)
        case .keyUp(let key, let modifiers):
            postKey(hidUsage: key, modifiers: modifiers, keyDown: false)
        }
    }

    private func globalPoint(nx: Double, ny: Double, selection: PickerSelection) -> CGPoint? {
        guard let rect = RemoteControlMapping.captureRect(for: selection) else { return nil }
        return RemoteControlMapping.globalPoint(nx: nx, ny: ny, captureRect: rect)
    }

    private func postMouse(
        type: CGEventType, at point: CGPoint, button: CGMouseButton, modifiers: KeyModifiers = []
    ) {
        lastPoint = point  // so a revoke can synthesize a button-up here
        let flags = Self.eventFlags(modifiers)
        if let hook = onInjectForTesting {
            hook(Self.testAction(for: type, button: button, flags: flags.rawValue))
            return
        }
        // Warp the hardware cursor so it visibly tracks the viewer.
        _ = CGWarpMouseCursorPosition(point)
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        // Modified clicks (⌘-click) need flags on the event itself.
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func testAction(
        for type: CGEventType, button: CGMouseButton, flags: UInt64
    ) -> InjectedAction {
        let side: InjectedAction.Side
        switch button {
        case .left: side = .left
        case .right: side = .right
        case .center: side = .middle
        @unknown default: side = .middle
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .mouseDown(side, flags: flags)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .mouseUp(side, flags: flags)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .drag(side)
        default: return .mouseMoved
        }
    }

    private func postScroll(deltaX: Double, deltaY: Double, modifiers: KeyModifiers) {
        // Wire deltas are usually a fraction of a line (trackpad scaling), so
        // they're banked, not rounded per event — rounding drops every
        // sub-line gesture. The accumulator also absorbs NaN/infinity/out-of-range.
        guard let wheel = scrollAccumulator.take(deltaX: deltaX, deltaY: deltaY) else {
            // Distinguishes "no scroll arrived" from "arrived, moved nothing
            // yet" — identical on screen otherwise.
            InputDebugLog.log(
                String(
                    format: "sharer scroll wire dx=%.3f dy=%.3f → banked, nothing injected",
                    deltaX, deltaY))
            return
        }
        InputDebugLog.log(
            String(
                format: "sharer scroll wire dx=%.3f dy=%.3f → wheel x=%d y=%d",
                deltaX, deltaY, wheel.wheelX, wheel.wheelY))
        if let hook = onInjectForTesting {
            hook(
                .scroll(
                    wheelY: wheel.wheelY, wheelX: wheel.wheelX,
                    flags: Self.eventFlags(modifiers).rawValue))
            return
        }
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: wheel.wheelY,
                wheel2: wheel.wheelX, wheel3: 0)
        else { return }
        // Shift-scroll and friends are interpreted app-side from event flags.
        event.flags = Self.eventFlags(modifiers)
        event.post(tap: .cghidEventTap)
    }

    private func postKey(hidUsage: UInt16, modifiers: KeyModifiers, keyDown: Bool) {
        // Usages with no mac key (Insert, PrintScreen, ...) are dropped
        // rather than injected wrong.
        guard let keyCode = MacKeyCodeMapping.macKeyCode(forHIDUsage: hidUsage) else { return }
        let flags = Self.eventFlags(modifiers)
        if let hook = onInjectForTesting {
            let action: InjectedAction
            if keyDown {
                action = .keyDown(keyCode: keyCode, flags: flags.rawValue)
            } else {
                action = .keyUp(keyCode: keyCode, flags: flags.rawValue)
            }
            hook(action)
            return
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
