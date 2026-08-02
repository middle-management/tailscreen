import TailscreenProtocol
import XCTest

@testable import XTestInjectKit

/// The Linux injector's decisions, through the `onInjectForTesting` seam so no
/// real `XTestFake*` runs and no cursor moves.
///
/// Deliberately the same suite as `SendInputInjectorTests`, case for case,
/// because the two injectors must agree about everything except how they talk
/// to the OS: a revoke must not leave a button held, a modified key must press
/// and unwind its modifiers, an unmappable usage must be dropped. Where a case
/// has no Windows counterpart — scroll-as-buttons, the flush — it is because
/// X11 genuinely differs, and those are the ones worth reading.
final class XTestInjectorTests: XCTestCase {
    private let region = XTestInjector.Region(x: 0, y: 0, width: 1920, height: 1080)

    private func makeInjector() -> (XTestInjector, () -> [XTestInjector.InjectedAction]) {
        let injector = XTestInjector()
        let box = ActionBox()
        injector.onInjectForTesting = { box.append($0) }
        return (injector, { box.drain() })
    }

    /// Actions arrive on the injector's serial queue, so the collector needs
    /// its own lock — a plain array would be a data race the sanitizer finds
    /// before any assertion does.
    private final class ActionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [XTestInjector.InjectedAction] = []
        func append(_ action: XTestInjector.InjectedAction) {
            lock.withLock { actions.append(action) }
        }
        func drain() -> [XTestInjector.InjectedAction] {
            lock.withLock {
                let snapshot = actions
                actions.removeAll()
                return snapshot
            }
        }
    }

    // MARK: The gate

    func testClosedGateDropsEverything() {
        let (injector, drain) = makeInjector()
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        XCTAssertTrue(drain().isEmpty, "input before any grant must not reach the desktop")
    }

    func testDeactivateDropsEventsThatRacedTheRevoke() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.deactivate()
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        XCTAssertTrue(
            drain().allSatisfy { $0 == .flush },
            "an event enqueued after deactivate must never be injected")
    }

    func testActivateDropsAPreviousGranteesQueue() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseMove(x: 0.1, y: 0.1))
        // A second grant before the first's queue drained: those events belong
        // to a viewer who no longer has control and must not be replayed under
        // the new one.
        injector.activate(region: region)
        injector.drainSyncForTesting()
        let motions = drain().filter {
            if case .motion = $0 { return true }
            return false
        }
        XCTAssertTrue(motions.isEmpty, "a new grant must not replay the old grantee's events")
    }

    // MARK: Stuck buttons

    func testRevokeMidDragReleasesTheHeldButton() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left, modifiers: []))
        injector.drainSyncForTesting()
        _ = drain()

        injector.deactivate()
        injector.drainSyncForTesting()
        // On X11 this matters more than anywhere else: a held button grabs the
        // pointer, so a stuck one doesn't merely misbehave — it makes the
        // sharer's whole desktop unusable.
        XCTAssertTrue(
            drain().contains(.button(number: 1, down: false)),
            "a revoke mid-drag must synthesize the button-up")
    }

    func testRevokeWithNothingHeldSynthesizesNothing() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .middle, modifiers: []))
        injector.apply(.mouseUp(x: 0.5, y: 0.5, button: .middle, modifiers: []))
        injector.drainSyncForTesting()
        _ = drain()

        injector.deactivate()
        injector.drainSyncForTesting()
        XCTAssertTrue(
            drain().isEmpty,
            "a button already released must not be released a second time")
    }

    // MARK: Coordinates

    func testNormalizedCoordinatesMapIntoTheRegion() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseMove(x: 1.0, y: 1.0))
        injector.drainSyncForTesting()
        // The last addressable pixel, not the width — the off-by-one that
        // makes the screen edge unclickable.
        XCTAssertEqual(drain().first, .motion(x: 1919, y: 1079))
    }

    func testOutOfRangeCoordinatesClampIntoTheRegion() {
        let (injector, drain) = makeInjector()
        injector.activate(region: XTestInjector.Region(x: 100, y: 50, width: 800, height: 600))
        injector.apply(.mouseMove(x: 5.0, y: -5.0))
        injector.drainSyncForTesting()
        // A hostile viewer must not be able to place the pointer outside the
        // region its user can see.
        XCTAssertEqual(drain().first, .motion(x: 100 + 799, y: 50))
    }

    // MARK: Scroll — the X11-specific one

    func testScrollBecomesButtonPressPairs() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: 2, modifiers: []))
        injector.drainSyncForTesting()
        let actions = drain()
        // Positive deltaY is a wheel rotation away from the user → button 4,
        // twice, each a complete press and release.
        XCTAssertEqual(
            actions.filter { $0 != .flush },
            [
                // 0.5 × (1920 − 1) = 959.5, which rounds up.
                .motion(x: 960, y: 540),
                .button(number: 4, down: true), .button(number: 4, down: false),
                .button(number: 4, down: true), .button(number: 4, down: false)
            ])
    }

    func testScrollPositionsThePointerFirst() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.scroll(x: 0.25, y: 0.75, deltaX: 0, deltaY: -1, modifiers: []))
        injector.drainSyncForTesting()
        // X11 delivers a scroll to whatever is under the pointer, so a scroll
        // that doesn't move there first scrolls the wrong window.
        guard case .motion = drain().first else {
            return XCTFail("a scroll must position the pointer before pressing")
        }
    }

    func testScrollButtonsAreNotTrackedAsHeld() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: 1, modifiers: []))
        injector.drainSyncForTesting()
        _ = drain()

        injector.deactivate()
        injector.drainSyncForTesting()
        // Each notch is a complete press+release, so there is nothing for a
        // revoke to strand — and synthesizing a release for button 4 would be
        // an extra scroll.
        XCTAssertTrue(drain().isEmpty, "scroll buttons must not be released again on revoke")
    }

    // MARK: Keys

    func testModifiersArePressedAroundTheKeyAndUnwoundInReverse() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.keyDown(key: 0x06, modifiers: [.control, .shift]))  // Ctrl+Shift+C
        injector.apply(.keyUp(key: 0x06, modifiers: [.control, .shift]))
        injector.drainSyncForTesting()
        XCTAssertEqual(
            drain().filter { $0 != .flush },
            [
                .key(keysym: 0xFFE3, down: true),  // Control_L
                .key(keysym: 0xFFE1, down: true),  // Shift_L
                .key(keysym: 0x0063, down: true),  // c
                .key(keysym: 0x0063, down: false),
                // Reverse, so Ctrl isn't released while Shift is still down.
                .key(keysym: 0xFFE1, down: false),
                .key(keysym: 0xFFE3, down: false)
            ])
    }

    func testCapsLockIsNeverSynthesizedAsAModifier() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.keyDown(key: 0x04, modifiers: [.capsLock]))  // a, caps on
        injector.drainSyncForTesting()
        // Caps Lock is a toggle: pressing it would flip the sharer's actual
        // Caps state and leave it flipped after the viewer left.
        XCTAssertEqual(
            drain().filter { $0 != .flush }, [.key(keysym: 0x0061, down: true)])
    }

    func testUnmappableHIDUsageIsDroppedNotGuessed() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        for usage in X11KeyCodeMapping.deliberatelyUnmapped {
            injector.apply(.keyDown(key: usage, modifiers: []))
        }
        injector.drainSyncForTesting()
        XCTAssertTrue(
            drain().allSatisfy { $0 == .flush },
            "a usage with no unambiguous keysym must be dropped, never guessed at")
    }

    // MARK: Flush — no X11 output happens without it

    func testEachDrainedBatchIsFlushed() {
        let (injector, drain) = makeInjector()
        injector.activate(region: region)
        injector.apply(.mouseMove(x: 0.5, y: 0.5))
        injector.drainSyncForTesting()
        // Xlib queues requests client-side. Without the flush nothing reaches
        // the server at all — the single most likely way for this file to look
        // broken while every other assertion here passes.
        XCTAssertEqual(drain().last, .flush)
    }
}
