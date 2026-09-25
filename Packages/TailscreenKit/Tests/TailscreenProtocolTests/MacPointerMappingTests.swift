import XCTest

@testable import TailscreenProtocol

/// `MacPointerMapping.ScrollLineAccumulator` — wire-delta → `CGEvent`
/// whole-line arithmetic. `CGEvent`'s `.line` unit is `Int32`; a trackpad
/// sends sub-line deltas, and rounding each one independently would zero out
/// every ordinary two-finger scroll.
final class MacPointerMappingTests: XCTestCase {
    func testWholeLinesPassStraightThrough() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        let out = acc.take(deltaX: 0, deltaY: -3)
        XCTAssertEqual(out?.wheelY, -3)
        XCTAssertEqual(out?.wheelX, 0)
        XCTAssertTrue(acc.isEmpty, "an exact line count leaves nothing owed")
    }

    func testSubLineDeltasAccumulateIntoAWholeLine() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.3))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.3))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.3))
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 0.3)?.wheelY, 1)
    }

    /// Ten 0.5-line events are five lines, not zero (truncation) or ten (a floor).
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
        // Half a line down, a full line right: vertical fraction is kept, not lost.
        let first = acc.take(deltaX: 1, deltaY: 0.5)
        XCTAssertEqual(first?.wheelX, 1)
        XCTAssertEqual(first?.wheelY, 0)
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 0.5)?.wheelY, 1)
    }

    /// Rounds toward zero: rounding to nearest would owe a remainder in the
    /// opposite direction, making the next event scroll nothing.
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
        // Without the reset this would ride the old 0.9 into a line the next grantee never scrolled.
        XCTAssertNil(acc.take(deltaX: 0.2, deltaY: 0.2))
    }

    // MARK: wire-supplied hostility

    func testNonFiniteDeltasContributeNothingAndDoNotPoisonTheBank() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertNil(acc.take(deltaX: .nan, deltaY: .infinity))
        XCTAssertNil(acc.take(deltaX: 0, deltaY: -.infinity))
        XCTAssertTrue(acc.isEmpty)
        // A NaN must not leave the accumulator permanently stuck.
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 2)?.wheelY, 2)
    }

    func testAbsurdDeltaIsClampedToTheCeiling() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        XCTAssertEqual(acc.take(deltaX: 0, deltaY: 1e9)?.wheelY, MacPointerMapping.maxLinesPerEvent)
        XCTAssertEqual(
            acc.take(deltaX: 0, deltaY: -1e9)?.wheelY, -MacPointerMapping.maxLinesPerEvent)
    }

    /// Banking the excess would keep firing max-rate scrolls long after the hostile event.
    func testClampedExcessIsDiscardedRatherThanBanked() {
        var acc = MacPointerMapping.ScrollLineAccumulator()
        _ = acc.take(deltaX: 0, deltaY: 1e9)
        XCTAssertTrue(acc.isEmpty)
        XCTAssertNil(acc.take(deltaX: 0, deltaY: 0.1))
    }
}
