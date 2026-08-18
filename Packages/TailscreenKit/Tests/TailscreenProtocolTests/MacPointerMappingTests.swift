import XCTest

@testable import TailscreenProtocol

/// Tests for `MacPointerMapping.ScrollLineAccumulator` — the wire-delta →
/// `CGEvent` whole-line arithmetic behind remote-control scrolling on macOS.
///
/// The bug this type exists for is invisible on a mouse and total on a
/// trackpad: `CGEvent`'s `.line` scroll unit is an `Int32`, a trackpad viewer
/// sends fractions of a line, and rounding each event on its own turned every
/// ordinary two-finger scroll into nothing at all. So the cases below are
/// mostly about what must NOT be discarded.
final class MacPointerMappingTests: XCTestCase {
    func testWholeLinesPassStraightThrough() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        let out = acc.take(deltaX: 0, deltaY: -3)
        XCTAssertEqual(out?.wheelY, -3)
        XCTAssertEqual(out?.wheelX, 0)
        XCTAssertTrue(acc.isEmpty, "an exact line count leaves nothing owed")
    }

    /// The headline case: a slow trackpad gesture is a stream of sub-line
    /// deltas, and every one of them used to round to zero.
    func testSubLineDeltasAccumulateIntoAWholeLine() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.3))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.3))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.3))
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 0.3)?.wheelY, 1)
    }

    /// Total distance is conserved: ten 0.5-line events are five lines, not
    /// zero (truncation) and not ten (a `max(…, 1)` floor).
    func testTotalScrolledDistanceIsConserved() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        var total: Int32 = 0
        for _ in 0..<10 {
            total += acc.take(deltaX: 0, deltaY: 0.5)?.wheelY ?? 0
        }
        XCTAssertEqual(total, 5)
    }

    func testAxesBankIndependently() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        // Half a line down, a full line right: only the horizontal axis has a
        // whole unit to deliver, and the vertical fraction is kept, not lost.
        let first = acc.take(deltaX: 1, deltaY: 0.5)
        XCTAssertEqual(first?.wheelX, 1)
        XCTAssertEqual(first?.wheelY, 0)
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 0.5)?.wheelY, 1)
    }

    /// Toward zero, not nearest: a 0.6 that emitted a whole line would owe
    /// 0.4 back in the opposite direction, and the next 0.6 would scroll
    /// nothing — a gesture that stutters instead of moving.
    func testRemainderKeepsTheSignOfTheMovement() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.6))
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 0.6)?.wheelY, 1)
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.6))
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 0.6)?.wheelY, 1)
    }

    func testDirectionReversalCancelsThePendingFraction() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.7))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: -0.7))
        XCTAssertTrue(acc.isEmpty)
    }

    func testResetDropsWhatWasOwed() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: 0.9, deltaY: 0.9))
        XCTAssertFalse(acc.isEmpty)
        acc.reset()
        XCTAssertTrue(acc.isEmpty)
        // Without the reset this 0.2 would ride the old 0.9 into a full line
        // the next grantee never scrolled.
        XCTAssertNil(acc.take(deltaX: 0.2, deltaY: 0.2))
    }

    // MARK: wire-supplied hostility

    func testNonFiniteDeltasContributeNothingAndDoNotPoisonTheBank() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: .nan, deltaY: .infinity))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: -.infinity))
        XCTAssertTrue(acc.isEmpty)
        // Still healthy afterwards — a NaN must not leave the accumulator in a
        // state where nothing scrolls ever again.
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 2)?.wheelY, 2)
    }

    func testAbsurdDeltaIsClampedToTheCeiling() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 1e9)?.wheelY, MacPointerMapping.maxLinesPerEvent)
        XCTAssertEqual(
            acc.take(deltaX: 0, deltaY: -1e9)?.wheelY, -MacPointerMapping.maxLinesPerEvent)
    }

    /// A clamp that banked the excess would keep firing max-rate scrolls long
    /// after the hostile event, so the overflow is dropped rather than owed.
    func testClampedExcessIsDiscardedRatherThanBanked() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        _ = acc.take(deltaX: 0, deltaY: 1e9)
        XCTAssertTrue(acc.isEmpty)
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.1))
    }
}
