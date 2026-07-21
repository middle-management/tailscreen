import XCTest

@testable import TailscreenProtocol

/// Unit tests for the shared UDP receive-loop retry policy — the capped
/// exponential backoff, the consecutive and windowed give-up thresholds, and
/// the elapsed-time `readFailed` dead-socket classification both the
/// server's control loop and the client's receive loop consult after a
/// receive error. Pure math, no tsnet — same pattern as
/// `AdaptiveBitrateTests`.
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

    // MARK: - readFailed classification

    func testNearInstantReadFailedIsAnError() {
        // Dead fd: poll returns immediately with POLLHUP and the read fails
        // in microseconds — must count toward the give-up ladder, not reset
        // it (that reset was the busy-spin bug).
        XCTAssertTrue(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 0))
        XCTAssertTrue(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 50_000))
        XCTAssertTrue(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 199_999_999))
    }

    func testWaitedOutReadFailedIsABenignTimeout() {
        // A genuine poll timeout returns only after its full 1 s interval.
        XCTAssertFalse(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 1_000_000_000))
        XCTAssertFalse(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 950_000_000))
    }

    func testReadFailedClassificationBoundary() {
        let boundary = ReceiveLoopPolicy.readFailedErrorMaxElapsedNs
        XCTAssertEqual(boundary, 200_000_000)
        // Strictly-less-than: exactly at the boundary reads as a timeout.
        XCTAssertTrue(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: boundary - 1))
        XCTAssertFalse(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: boundary))
    }

    func testClassificationBoundarySitsWellBelowThePollTimeout() {
        // Both loops poll with a 1 s timeout; the classifier must never
        // mistake a real timeout for an error.
        XCTAssertLessThan(ReceiveLoopPolicy.readFailedErrorMaxElapsedNs, 1_000_000_000)
    }

    // MARK: - Windowed give-up backstop

    private let s: UInt64 = 1_000_000_000

    func testWindowedErrorCountAccumulates() {
        var stamps: [UInt64] = []
        XCTAssertEqual(ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: 100 * s), 1)
        XCTAssertEqual(ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: 110 * s), 2)
        XCTAssertEqual(ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: 120 * s), 3)
    }

    func testOldErrorsAgeOutOfWindow() {
        var stamps: [UInt64] = []
        for t in [100, 110, 120] {
            _ = ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: UInt64(t) * s)
        }
        // 70 s later the three earlier errors are outside the 60 s window;
        // a fresh error counts as #1 again.
        XCTAssertEqual(ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: 190 * s), 1)
        XCTAssertEqual(stamps, [190 * s])
    }

    func testErrorExactlyAtWindowEdgeStillCounts() {
        // Pruning is strictly greater-than, matching the crash-budget
        // precedent (`slidingWindowCrashCount`).
        var stamps: [UInt64] = [100 * s]
        XCTAssertEqual(ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: 160 * s), 2)
    }

    func testAlternatingErrorsReachTheWindowedThreshold() {
        // The backstop's whole point: errors spaced out by timeouts (which
        // reset the consecutive counter) still accumulate in the window.
        // 30 errors 1 s apart all fit inside 60 s.
        var stamps: [UInt64] = []
        var worst = 0
        for t in 0..<ReceiveLoopPolicy.maxErrorsPerWindow {
            worst = ReceiveLoopPolicy.slidingWindowErrorCount(&stamps, appending: UInt64(t) * s)
        }
        XCTAssertGreaterThanOrEqual(worst, ReceiveLoopPolicy.maxErrorsPerWindow)
    }

    func testDocumentedWindowConstants() {
        XCTAssertEqual(ReceiveLoopPolicy.maxErrorsPerWindow, 30)
        XCTAssertEqual(ReceiveLoopPolicy.errorWindowNs, 60_000_000_000)
        // The windowed threshold must be laxer than the consecutive one, or
        // it would preempt the faster consecutive give-up.
        XCTAssertGreaterThan(
            ReceiveLoopPolicy.maxErrorsPerWindow, ReceiveLoopPolicy.maxConsecutiveErrors)
    }
}
