import AppKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Tests the injector's revoke gate, stuck-button release, and the
/// wire-neutral → CGEvent translation (HID usage → mac keycode,
/// `KeyModifiers` → `CGEventFlags`) via the `onInjectForTesting` seam (no
/// real `CGEventPost`, so the CI cursor is never warped). The coordinate
/// mapping itself is covered by `RemoteControlMappingTests`, and the
/// kVK↔HID table by `MacKeyCodeMappingTests`.
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

    // MARK: - Neutral-wire → CGEvent translation (supersedes the old raw-flag
    // masking: flags are now *constructed* from the neutral bits, so nothing
    // wire-supplied can reach CGEventFlags unmasked)

    func testEventFlagsTranslatesEachNeutralBit() {
        XCTAssertEqual(RemoteControlInjector.eventFlags([.shift]), [.maskShift])
        XCTAssertEqual(RemoteControlInjector.eventFlags([.control]), [.maskControl])
        XCTAssertEqual(RemoteControlInjector.eventFlags([.alt]), [.maskAlternate])
        XCTAssertEqual(RemoteControlInjector.eventFlags([.meta]), [.maskCommand])
        XCTAssertEqual(RemoteControlInjector.eventFlags([.capsLock]), [.maskAlphaShift])
        XCTAssertEqual(
            RemoteControlInjector.eventFlags([.meta, .shift]), [.maskCommand, .maskShift])
    }

    func testEventFlagsIgnoresUnknownWireBits() {
        // A hostile viewer setting every bit of the wire bitmask gets exactly
        // the five known modifiers translated — nothing else.
        let everything = KeyModifiers(rawValue: .max)
        XCTAssertEqual(
            RemoteControlInjector.eventFlags(everything),
            RemoteControlInjector.eventFlags(KeyModifiers.allKnown))
    }

    func testViewerModifierCaptureRoundTripsThroughInjector() {
        // NSEvent flags → neutral wire bits → CGEventFlags, end to end.
        let wire = RemoteControlInputView.keyModifiers(from: [.command, .shift])
        XCTAssertEqual(wire, [.meta, .shift])
        XCTAssertEqual(RemoteControlInjector.eventFlags(wire), [.maskCommand, .maskShift])
    }

    func testKeyEventTranslatesHIDUsageToMacKeyCode() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        // HID 0x28 (Enter) with every wire bit set → kVK 0x24 (Return) with
        // only the known modifiers translated.
        injector.apply(.keyDown(key: 0x28, modifiers: KeyModifiers(rawValue: .max)))
        injector.drainSyncForTesting()
        XCTAssertEqual(
            recorder.all,
            [
                .keyDown(
                    keyCode: 0x24,
                    flags: RemoteControlInjector.eventFlags(KeyModifiers.allKnown).rawValue)
            ])
    }

    func testUnmappableHIDUsageIsDroppedNotGuessed() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        // HID 0x49 (Insert) has no mac key; injecting a guess would type the
        // wrong character, so the event must vanish.
        injector.apply(.keyDown(key: 0x49, modifiers: []))
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.all.isEmpty)
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
        injector.apply(.mouseDown(x: 0.4, y: 0.6, button: .left, modifiers: []))
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
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.left, flags: 0)])

        // Revoke mid-drag: the injector must release the held button.
        injector.deactivate()
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.left, flags: 0), .mouseUp(.left, flags: 0)])
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
        injector.apply(.mouseDown(x: 0.1, y: 0.1, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        injector.apply(.mouseMove(x: 0.2, y: 0.2))
        injector.drainSyncForTesting()
        injector.apply(.mouseUp(x: 0.2, y: 0.2, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.left, flags: 0), .drag(.left), .mouseUp(.left, flags: 0)])
    }

    func testModifiedClickCarriesTranslatedFlagsToInjection() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        // A ⌘-click must reach the injection layer with maskCommand set on
        // the mouse event itself — apps read modifiers off the event.
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left, modifiers: [.meta]))
        injector.apply(.mouseUp(x: 0.5, y: 0.5, button: .left, modifiers: [.meta]))
        injector.apply(.scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: -2, modifiers: [.shift]))
        injector.drainSyncForTesting()
        XCTAssertEqual(
            recorder.all,
            [
                .mouseDown(.left, flags: CGEventFlags.maskCommand.rawValue),
                .mouseUp(.left, flags: CGEventFlags.maskCommand.rawValue),
                .scroll(flags: CGEventFlags.maskShift.rawValue)
            ])
    }

    func testMiddleButtonDragAndRevokeRelease() {
        let (injector, recorder) = makeInjector()
        injector.activate(selection: displaySelection)
        injector.apply(.mouseDown(x: 0.1, y: 0.1, button: .middle, modifiers: []))
        injector.drainSyncForTesting()
        injector.apply(.mouseMove(x: 0.2, y: 0.2))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.all, [.mouseDown(.middle, flags: 0), .drag(.middle)])

        // Revoke while the middle button is held — same stuck-button
        // guarantee as left/right.
        injector.deactivate()
        injector.drainSyncForTesting()
        XCTAssertEqual(
            recorder.all, [.mouseDown(.middle, flags: 0), .drag(.middle), .mouseUp(.middle, flags: 0)])
    }
}
