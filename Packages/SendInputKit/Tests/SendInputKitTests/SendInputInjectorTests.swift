import TailscreenProtocol
import XCTest

@testable import SendInputKit

/// Tests for `SendInputInjector` — the grant gate, the modifier synthesis and
/// the stuck-button release.
///
/// They run everywhere, including Linux CI, because every assertion goes
/// through `onInjectForTesting`: no real `SendInput`, so no cursor is flung
/// across whatever machine happens to be running them. What is left unchecked
/// is only the handful of Win32 calls in the shim.
///
/// The two behaviours most worth pinning are both about what happens when a
/// grant ENDS, because those are the ones a user experiences as their own
/// machine being broken: an event that raced the revoke still landing, and a
/// button left held down with nobody able to release it.
final class SendInputInjectorTests: XCTestCase {
    private let region = WindowsPointerMapping.ScreenRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Collects injected actions. A class so the escaping hook can append.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SendInputInjector.InjectedAction] = []

        func record(_ action: SendInputInjector.InjectedAction) {
            lock.withLock { items.append(action) }
        }
        var actions: [SendInputInjector.InjectedAction] { lock.withLock { items } }
        func reset() { lock.withLock { items.removeAll() } }
    }

    /// A fixed 1920×1080 desktop at the origin, so the absolute coordinates
    /// below are stable arithmetic rather than whatever monitors the machine
    /// running the tests happens to have.
    private func makeInjector(
        desktop: WindowsPointerMapping.ScreenRect? = nil
    ) -> (SendInputInjector, Recorder) {
        let injector = SendInputInjector()
        let bounds = desktop ?? region
        injector.virtualDesktopProvider = { bounds }
        let recorder = Recorder()
        injector.onInjectForTesting = { recorder.record($0) }
        return (injector, recorder)
    }

    // MARK: The gate

    func testEventsBeforeAGrantAreDropped() {
        let (injector, recorder) = makeInjector()
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.actions.isEmpty, "no grant, no injection")
    }

    func testEventsAfterActivateAreInjected() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseMove(x: 0, y: 0))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.actions, [.move(x: 0, y: 0)])
    }

    func testDeactivateDropsEventsThatRacedTheRevoke() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        // Enqueued, then revoked before the queue drains — the TOCTOU an
        // `active` flag checked only at enqueue time would let through.
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.deactivate()
        injector.drainSyncForTesting()
        XCTAssertEqual(
            recorder.actions.filter { if case .move = $0 { return true } else { return false } },
            [], "an event queued before the revoke must not land after it")
    }

    func testEventsAfterDeactivateAreDropped() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.deactivate()
        injector.drainSyncForTesting()
        recorder.reset()

        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.actions.isEmpty)
    }

    func testActivateDoesNotReplayAPreviousGrantsQueue() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseMove(x: 0.9, y: 0.9))
        injector.deactivate()
        recorder.reset()

        // A new viewer is granted control. Nothing the previous one sent may
        // arrive under their grant.
        injector.activate(region: region)
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.actions.isEmpty)
    }

    // MARK: Stuck buttons

    func testRevokeMidDragReleasesTheHeldButton() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseDown(x: 0.25, y: 0.25, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        recorder.reset()

        injector.deactivate()
        injector.drainSyncForTesting()

        // Without this, the sharer is left with a button held down and no
        // input path able to release it — the drag continues forever.
        XCTAssertEqual(recorder.actions.count, 1)
        guard case .button(let index, let down, _, _)? = recorder.actions.first else {
            return XCTFail("expected a synthesized button-up")
        }
        XCTAssertEqual(index, 0)
        XCTAssertFalse(down)
    }

    func testMiddleButtonIsReleasedToo() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .middle, modifiers: []))
        injector.drainSyncForTesting()
        recorder.reset()

        injector.deactivate()
        injector.drainSyncForTesting()
        // The release lands where the press did: (0.5, 0.5) of a 1920×1080
        // desktop is pixel (960, 540), which is 32776/32784 in absolute units
        // — past the midpoint, because the range spans `extent - 1`.
        XCTAssertEqual(recorder.actions.count, 1)
        guard case .button(let index, let down, let x, _)? = recorder.actions.first else {
            return XCTFail("expected a synthesized button-up")
        }
        XCTAssertEqual(index, 2)
        XCTAssertFalse(down)
        XCTAssertGreaterThan(x, 32000, "released where it was pressed, not at the origin")
    }

    func testAReleasedButtonIsNotReleasedAgain() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left, modifiers: []))
        injector.apply(.mouseUp(x: 0.5, y: 0.5, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        recorder.reset()

        injector.deactivate()
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.actions.isEmpty, "nothing was held")
    }

    // MARK: Keys

    func testModifiersArePressedAroundTheKey() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        // HID usage 0x06 is 'c'. Ctrl+C.
        injector.apply(.keyDown(key: 0x06, modifiers: [.control]))
        injector.drainSyncForTesting()

        // Windows has no per-event modifier field the way CGEvent does: the
        // modifier must actually be held, so it is pressed first.
        XCTAssertEqual(recorder.actions.count, 2)
        XCTAssertEqual(recorder.actions.first, .key(virtualKey: 0x11, extended: false, down: true))
        guard case .key(let vk, _, let down)? = recorder.actions.last else {
            return XCTFail("expected the key itself")
        }
        XCTAssertEqual(vk, 0x43, "HID 0x06 is 'c', VK_C is 0x43")
        XCTAssertTrue(down)
    }

    func testModifiersAreReleasedInReverseOrderAfterTheKeyUp() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.keyUp(key: 0x06, modifiers: [.control, .shift]))
        injector.drainSyncForTesting()

        // key up, then shift up, then ctrl up: unwound the way it was built,
        // so Ctrl is never released while Shift is still down.
        XCTAssertEqual(recorder.actions.count, 3)
        guard case .key(let first, _, _)? = recorder.actions.first else {
            return XCTFail("expected the key first")
        }
        XCTAssertEqual(first, 0x43)
        XCTAssertEqual(recorder.actions[1], .key(virtualKey: 0x10, extended: false, down: false))
        XCTAssertEqual(recorder.actions[2], .key(virtualKey: 0x11, extended: false, down: false))
    }

    func testCapsLockIsNeverSynthesized() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.keyDown(key: 0x06, modifiers: [.capsLock]))
        injector.drainSyncForTesting()

        // Caps Lock is a TOGGLE, not a held modifier: pressing it would flip
        // the sharer's real Caps state and leave it flipped.
        XCTAssertEqual(recorder.actions.count, 1, "only the key itself")
        XCTAssertEqual(
            SendInputInjector.modifierKeys([.capsLock]), [],
            "caps lock is deliberately absent from the synthesized set")
    }

    func testUnmappableHIDUsageIsDroppedNotGuessed() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        // 0x67 is Keypad = — in `deliberatelyUnmapped`, because Windows has no
        // VK for it. Guessing would type the wrong character.
        injector.apply(.keyDown(key: 0x67, modifiers: []))
        injector.drainSyncForTesting()
        XCTAssertTrue(recorder.actions.isEmpty)
    }

    func testExtendedKeysCarryTheirFlag() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        // HID 0x4F is Right Arrow, which on Windows is VK_RIGHT + extended.
        // Without the extended bit it is the numpad 6 instead.
        injector.apply(.keyDown(key: 0x4F, modifiers: []))
        injector.drainSyncForTesting()
        guard case .key(let vk, let extended, _)? = recorder.actions.first else {
            return XCTFail("expected a key event")
        }
        XCTAssertEqual(vk, 0x27, "VK_RIGHT")
        XCTAssertTrue(extended)
    }

    // MARK: Pointer and scroll

    func testScrollConvertsLinesToWheelUnits() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        injector.apply(.scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: -2, modifiers: []))
        injector.drainSyncForTesting()
        XCTAssertEqual(recorder.actions, [.scroll(wheelY: -240, wheelX: 0)])
    }

    func testConsecutiveMovesAreCoalescedButClicksAreNot() {
        let (injector, recorder) = makeInjector()
        injector.activate(region: region)
        // Enqueued together so they drain as one batch, which is the case the
        // coalescer exists for.
        injector.apply(.mouseMove(x: 0.1, y: 0.1))
        injector.apply(.mouseMove(x: 0.2, y: 0.2))
        injector.apply(.mouseMove(x: 1.0, y: 1.0))
        injector.apply(.mouseDown(x: 1.0, y: 1.0, button: .left, modifiers: []))
        injector.drainSyncForTesting()

        let moves = recorder.actions.filter {
            if case .move = $0 { return true } else { return false }
        }
        XCTAssertLessThanOrEqual(moves.count, 3, "consecutive moves collapse")
        XCTAssertEqual(
            moves.last, .move(x: 65535, y: 65535),
            "the surviving move is the LAST position, not the first")
        XCTAssertTrue(
            recorder.actions.contains { if case .button = $0 { return true } else { return false } },
            "a button event is never dropped by coalescing")
    }

    func testTheRegionIsWhatNormalizedCoordinatesMapInto() {
        let (injector, recorder) = makeInjector()
        // A window occupying the right half of the desktop: nx == 0 must land
        // at the window's left edge, not the screen's.
        injector.activate(
            region: WindowsPointerMapping.ScreenRect(x: 960, y: 0, width: 960, height: 1080))
        injector.apply(.mouseMove(x: 0, y: 0))
        injector.drainSyncForTesting()

        guard case .move(let x, _)? = recorder.actions.first else {
            return XCTFail("expected a move")
        }
        XCTAssertGreaterThan(x, 0, "a window share's origin is not the desktop's origin")
    }
}
