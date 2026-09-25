import XCTest

@testable import TailscreenProtocol

/// The viewer transport's pure end-of-session decisions — the idle timeout and
/// the receive-error storm — tested with no socket, no tailnet, and no clock.
/// They live in `TransportEndDecision` rather than on the tsnet transport
/// because linking that tier needs `libtailscale.a`, which linux-protocol
/// never builds. Both guard against a frozen-forever session: a sharer that
/// crashed without a BYE, or a dead socket's errors swallowed by a bare `continue`.
final class TransportEndDecisionTests: XCTestCase {

    // MARK: - Idle timeout

    func testIdleUnderThresholdDoesNotFire() {
        XCTAssertFalse(
            TransportEndDecision.idleTimedOut(
                nowNs: 5_000_000_000, lastDatagramNs: 0, isPendingApproval: false,
                timeoutNs: 15_000_000_000))
    }

    /// The threshold is exclusive — exactly at the timeout is still alive,
    /// matching the macOS receive loop's `>` comparison.
    func testIdleExactlyAtThresholdDoesNotFire() {
        XCTAssertFalse(
            TransportEndDecision.idleTimedOut(
                nowNs: 15_000_000_000, lastDatagramNs: 0, isPendingApproval: false,
                timeoutNs: 15_000_000_000))
    }

    func testIdlePastThresholdFires() {
        XCTAssertTrue(
            TransportEndDecision.idleTimedOut(
                nowNs: 15_000_000_001, lastDatagramNs: 0, isPendingApproval: false,
                timeoutNs: 15_000_000_000))
    }

    /// A sharer deliberating over Accept/Deny legitimately sends nothing, so
    /// the approval wait must never time out. (Sharer prunes stale pending
    /// viewers on its own clock; Cancel is the way out here.)
    func testIdleSuppressedWhilePendingApproval() {
        XCTAssertFalse(
            TransportEndDecision.idleTimedOut(
                nowNs: 600_000_000_000, lastDatagramNs: 0, isPendingApproval: true,
                timeoutNs: 15_000_000_000))
    }

    /// Shared tuning constant, so server sweep and viewer disconnect stay in sync.
    func testIdleDefaultThresholdIsTheSharedTuningConstant() {
        XCTAssertFalse(
            TransportEndDecision.idleTimedOut(
                nowNs: TransportTuning.clientIdleDisconnectNs, lastDatagramNs: 0,
                isPendingApproval: false))
        XCTAssertTrue(
            TransportEndDecision.idleTimedOut(
                nowNs: TransportTuning.clientIdleDisconnectNs + 1, lastDatagramNs: 0,
                isPendingApproval: false))
    }

    // MARK: - Receive-error storm

    func testConsecutiveErrorsReachTheThresholdExactlyOnce() {
        var tally = TransportEndDecision.ReceiveFailureTally()
        // Every error short of the threshold keeps the loop alive…
        for i in 1..<ReceiveLoopPolicy.maxConsecutiveErrors {
            XCTAssertFalse(
                TransportEndDecision.receiveFailureIsFatal(
                    &tally, benignTimeout: false, nowNs: UInt64(i) * 1_000_000),
                "error #\(i) must not yet be fatal")
        }
        // …and the threshold-th one gives up.
        XCTAssertTrue(
            TransportEndDecision.receiveFailureIsFatal(
                &tally, benignTimeout: false,
                nowNs: UInt64(ReceiveLoopPolicy.maxConsecutiveErrors) * 1_000_000))
    }

    func testBenignTimeoutResetsTheConsecutiveRun() {
        var tally = TransportEndDecision.ReceiveFailureTally()
        for i in 1..<ReceiveLoopPolicy.maxConsecutiveErrors {
            _ = TransportEndDecision.receiveFailureIsFatal(
                &tally, benignTimeout: false, nowNs: UInt64(i) * 1_000_000)
        }
        // One ordinary poll timeout: the socket answered "nothing yet", which
        // is a healthy socket, so the run starts over.
        XCTAssertFalse(
            TransportEndDecision.receiveFailureIsFatal(&tally, benignTimeout: true, nowNs: 500_000_000))
        XCTAssertEqual(tally.consecutiveErrors, 0)
        // The next genuine error is #1 again, nowhere near fatal.
        XCTAssertFalse(
            TransportEndDecision.receiveFailureIsFatal(&tally, benignTimeout: false, nowNs: 600_000_000))
        XCTAssertEqual(tally.consecutiveErrors, 1)
    }

    /// The windowed backstop: a flapping socket whose errors interleave with
    /// timeouts resets the consecutive counter forever, and would poll
    /// forever without this trailing-window bound.
    func testErrorTimeoutAlternationTripsTheWindowedBackstop() {
        var tally = TransportEndDecision.ReceiveFailureTally()
        var fatalAt: Int?
        for i in 1...ReceiveLoopPolicy.maxErrorsPerWindow {
            let nowNs = UInt64(i) * 1_000_000_000
            if TransportEndDecision.receiveFailureIsFatal(&tally, benignTimeout: false, nowNs: nowNs) {
                fatalAt = i
                break
            }
            // Interleaved timeout keeps the consecutive counter at zero — the pattern the backstop exists for.
            XCTAssertFalse(
                TransportEndDecision.receiveFailureIsFatal(
                    &tally, benignTimeout: true, nowNs: nowNs + 500_000_000))
        }
        XCTAssertEqual(
            fatalAt, ReceiveLoopPolicy.maxErrorsPerWindow,
            "the windowed backstop must fire on the \(ReceiveLoopPolicy.maxErrorsPerWindow)th error, consecutive resets notwithstanding"
        )
    }

    /// Stamps older than the window are pruned: a burst an hour ago must not
    /// count against a socket healthy since.
    func testOldErrorsAgeOutOfTheWindow() {
        var tally = TransportEndDecision.ReceiveFailureTally()
        // Near-fatal burst at t≈0, defused below threshold by a trailing benign timeout.
        for i in 1...(ReceiveLoopPolicy.maxErrorsPerWindow - 1) {
            _ = TransportEndDecision.receiveFailureIsFatal(
                &tally, benignTimeout: false, nowNs: UInt64(i) * 1_000)
            _ = TransportEndDecision.receiveFailureIsFatal(
                &tally, benignTimeout: true, nowNs: UInt64(i) * 1_000 + 500)
        }
        // A full window later the old stamps are gone: error 1-of-30, not 30-of-30.
        let laterNs = ReceiveLoopPolicy.errorWindowNs * 2
        XCTAssertFalse(
            TransportEndDecision.receiveFailureIsFatal(&tally, benignTimeout: false, nowNs: laterNs))
        XCTAssertEqual(tally.errorStampsNs.count, 1, "aged-out stamps must be pruned")
    }
}
