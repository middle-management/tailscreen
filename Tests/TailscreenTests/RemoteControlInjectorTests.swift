import AppKit
import XCTest

@testable import Tailscreen

/// Tests the injector's revoke gate, stuck-button release, and modifier
/// masking via the `onInjectForTesting` seam (no real `CGEventPost`, so the
/// CI cursor is never warped). The coordinate mapping itself is covered by
/// `RemoteControlMappingTests`.
final class RemoteControlInjectorTests: XCTestCase {
    /// Serial-queue-safe recorder for the injected-action stream.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [RemoteControlInjector.InjectedAction] = []
        func record(_ action: RemoteControlInjector.InjectedAction) {
            lock.lock()
            defer { lock.unlock() }
            actions.append(action)
        }
        var all: [RemoteControlInjector.InjectedAction] {
            lock.lock()
            defer { lock.unlock() }
            return actions
        }
    }

    private func makeInjector() -> (RemoteControlInjector, Recorder) {
        let injector = RemoteControlInjector()
        let recorder = Recorder()
        injector.onInjectForTesting = { recorder.record($0) }
        return (injector, recorder)
    }

    private let displaySelection = PickerSelection(
        kind: .display, displayID: nil, windowID: nil, bundleIDs: [])

    // MARK: - Modifier masking (finding 6)

    func testMaskedFlagsDropsUnknownBits() {
        // Every bit set on the wire must reduce to exactly the allowed set.
        XCTAssertEqual(
            RemoteControlInjector.maskedFlags(.max), RemoteControlInjector.allowedModifierMask)
    }

    func testMaskedFlagsPreservesKnownCombo() {
        let combo = RemoteControlInputView.cgFlags(from: [.command, .shift])
        XCTAssertEqual(RemoteControlInjector.maskedFlags(combo), combo)
        // A stray high bit outside the allowed set is stripped, the combo kept.
        XCTAssertEqual(RemoteControlInjector.maskedFlags(combo | (UInt64(1) << 40)), combo)
    }

    func testKeyEventFlagsAreMaskedBeforeInjection() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.apply(.keyDown(keyCode: 0x24, modifiers: .max))
        injector.drainSyncForTesting()
        XCTAssertEqual(
            recorder.all,
            [.keyDown(keyCode: 0x24, flags: RemoteControlInjector.allowedModifierMask)])
    }

    // MARK: - Revoke gate (finding 3a)

    func testInactiveInjectorDropsInput() {
        let (injector, recorder) = makeInjector()
        // Never activated — the gate is closed.
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testDeactivateSealsAgainstLateInput() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.deactivate()
        injector.drainSyncForTesting()
        // Input arriving after revoke must never inject.
        injector.apply(.mouseMove(x: 0.4, y: 0.6))
        injector.apply(.mouseDown(x: 0.4, y: 0.6, button: .left))
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.all.isEmpty, "no input may inject after deactivate")
    }

    func testActivateAfterDeactivateReopensGate() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.deactivate()
        injector.drainSyncForTesting()
        injector.activate(selection: displaySelection)
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseMoved])
    }

    // MARK: - Stuck-button release on revoke (finding 3b)

    func testDeactivateSynthesizesButtonUpForHeldButton() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.left)])

        // Revoke mid-drag: the injector must release the held button.
        injector.deactivate()
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.left), .mouseUp(.left)])
    }

    func testDeactivateWithNoHeldButtonSynthesizesNothing() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        injector.deactivate()
        injector.drainSyncForTesting()
        // Only the move — no spurious button-up when nothing was pressed.
        XCTAssertEqual(recorder.all, [.mouseMoved])
    }

    func testDragUsesDraggedEventWhileButtonHeld() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.apply(.mouseDown(x: 0.1, y: 0.1, button: .left))
        injector.drainSyncForTesting()
        injector.apply(.mouseMove(x: 0.2, y: 0.2))
        injector.drainSyncForTesting()
        injector.apply(.mouseUp(x: 0.2, y: 0.2, button: .left))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.left), .drag(.left), .mouseUp(.left)])
    }
}
