import XCTest

@testable import TailscreenProtocol

/// Unit tests for the shared HID-usage → `KeyModifiers` table and the tracked
/// modifier set built on it, which the WinUI viewer maintains by hand (its
/// events carry no modifier snapshot) and the GTK viewer consults to decide
/// which key events to drop.
final class KeyModifierTrackingTests: XCTestCase {

    // MARK: - The table

    func testBothSidesOfEachModifierPairNameTheSameRole() {
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE1), .shift)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE5), .shift)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE0), .control)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE4), .control)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE2), .alt)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE6), .alt)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE3), .meta)
        XCTAssertEqual(KeyModifiers.heldModifier(forHIDUsage: 0xE7), .meta)
    }

    /// The GTK viewer used to answer this with `(0xE0...0xE7).contains`. That
    /// range and this switch must cover exactly the same usages, or the two
    /// viewers disagree about which key events to forward — so assert the
    /// equivalence rather than trusting that they were written to match.
    func testTheHeldModifierUsagesAreExactlyTheRange0xE0Through0xE7() {
        for usage in UInt16(0)...UInt16(0xFF) {
            XCTAssertEqual(
                KeyModifiers.heldModifier(forHIDUsage: usage) != nil,
                (0xE0...0xE7).contains(usage),
                "usage 0x\(String(usage, radix: 16)) disagrees with the range")
        }
    }

    /// Caps Lock is NOT a held modifier: it is a toggle with its own usage.
    func testCapsLockIsNotAHeldModifier() {
        XCTAssertNil(KeyModifiers.heldModifier(forHIDUsage: KeyModifiers.capsLockHIDUsage))
    }

    func testOrdinaryKeysNameNoModifier() {
        XCTAssertNil(KeyModifiers.heldModifier(forHIDUsage: 0x04))  // a
        XCTAssertNil(KeyModifiers.heldModifier(forHIDUsage: 0x28))  // Enter
        XCTAssertNil(KeyModifiers.heldModifier(forHIDUsage: 0x00))
    }

    // MARK: - Tracking

    func testHeldModifierIsInsertedOnDownAndRemovedOnUp() {
        var tracked: KeyModifiers = []
        XCTAssertTrue(tracked.trackHIDKeyEvent(usage: 0xE0, down: true))
        XCTAssertEqual(tracked, .control)
        XCTAssertTrue(tracked.trackHIDKeyEvent(usage: 0xE0, down: false))
        XCTAssertEqual(tracked, [])
    }

    /// Releasing the OTHER side of a pair clears the role. Both physical keys
    /// map to one wire bit, so there is no per-side bookkeeping to be had —
    /// and the alternative (a bit that only the same side can clear) would
    /// latch Shift forever for anyone who presses left and releases right.
    func testEitherSideOfAPairReleasesTheRole() {
        var tracked: KeyModifiers = []
        _ = tracked.trackHIDKeyEvent(usage: 0xE1, down: true)
        _ = tracked.trackHIDKeyEvent(usage: 0xE5, down: false)
        XCTAssertEqual(tracked, [])
    }

    func testModifiersAccumulate() {
        var tracked: KeyModifiers = []
        _ = tracked.trackHIDKeyEvent(usage: 0xE0, down: true)
        _ = tracked.trackHIDKeyEvent(usage: 0xE1, down: true)
        XCTAssertEqual(tracked, [.control, .shift])
    }

    /// The toggle rule. Caps Lock's down-event means the state FLIPPED, and
    /// there is no up-event to clear it — treat it as held and it latches on
    /// forever, silently upper-casing everything typed on the other machine.
    func testCapsLockTogglesOnDownAndIgnoresUp() {
        var tracked: KeyModifiers = []
        XCTAssertTrue(
            tracked.trackHIDKeyEvent(usage: KeyModifiers.capsLockHIDUsage, down: true))
        XCTAssertEqual(tracked, .capsLock)
        XCTAssertTrue(
            tracked.trackHIDKeyEvent(usage: KeyModifiers.capsLockHIDUsage, down: false))
        XCTAssertEqual(tracked, .capsLock, "the release must not clear a toggle")
        XCTAssertTrue(
            tracked.trackHIDKeyEvent(usage: KeyModifiers.capsLockHIDUsage, down: true))
        XCTAssertEqual(tracked, [], "the next press flips it back off")
    }

    /// An ordinary key reports false and leaves the set alone, which is what
    /// tells the caller to forward the event rather than swallow it.
    func testAnOrdinaryKeyIsNotClaimedAndChangesNothing() {
        var tracked: KeyModifiers = [.control]
        XCTAssertFalse(tracked.trackHIDKeyEvent(usage: 0x04, down: true))
        XCTAssertEqual(tracked, .control)
    }

    /// Everything the tracker can set stays inside the protocol's vocabulary,
    /// so nothing outside `allKnown` can reach an injector.
    func testTrackedSetNeverLeavesTheWireVocabulary() {
        var tracked: KeyModifiers = []
        for usage in UInt16(0)...UInt16(0xFF) {
            _ = tracked.trackHIDKeyEvent(usage: usage, down: true)
        }
        XCTAssertTrue(KeyModifiers.allKnown.isSuperset(of: tracked))
    }
}
