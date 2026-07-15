import XCTest

@testable import Tailscreen

/// Unit tests for the shared UDP receive-loop retry policy — the capped
/// exponential backoff and give-up threshold both the server's control loop
/// and the client's receive loop consult after a non-timeout receive error.
/// Pure math, no tsnet — same pattern as `AdaptiveBitrateTests`.
final class ReceiveLoopPolicyTests: XCTestCase {
    private func delay(_ consecutiveErrors: Int) -> UInt64 {
        ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: consecutiveErrors)
    }

    func testFirstRetryWaits250Milliseconds() {
        XCTAssertEqual(delay(1), 250_000_000)
    }

    func testDelayDoublesPerConsecutiveError() {
        XCTAssertEqual(delay(2), 500_000_000)
        XCTAssertEqual(delay(3), 1_000_000_000)
        XCTAssertEqual(delay(4), 2_000_000_000)
        XCTAssertEqual(delay(5), 4_000_000_000)
    }

    func testDelayCapsAtFiveSeconds() {
        XCTAssertEqual(delay(6), 5_000_000_000)
        XCTAssertEqual(delay(7), 5_000_000_000)
        XCTAssertEqual(delay(100), 5_000_000_000)
        // Absurd input must not overflow the shift.
        XCTAssertEqual(delay(Int.max), 5_000_000_000)
    }

    func testNonPositiveCountsClampToBaseDelay() {
        // The loops always call with a count ≥ 1; the clamp is defence
        // against a future refactor passing a pre-increment value.
        XCTAssertEqual(delay(0), 250_000_000)
        XCTAssertEqual(delay(-3), 250_000_000)
    }

    func testGiveUpThresholdBoundsTotalRetryTime() {
        XCTAssertEqual(ReceiveLoopPolicy.maxConsecutiveErrors, 10)
        // A loop that ultimately gives up sleeps through retries 1..<max;
        // the whole death spiral must resolve well within a minute so the
        // teardown isn't itself a hang.
        var totalNs: UInt64 = 0
        for n in 1..<ReceiveLoopPolicy.maxConsecutiveErrors {
            totalNs += delay(n)
        }
        XCTAssertLessThanOrEqual(totalNs, 60_000_000_000)
    }
}
