import XCTest

@testable import TailscreenProtocol

/// The viewer transport's pure end-of-session decisions — the idle timeout and
/// the receive-error storm — tested with no socket, no tailnet, and no clock.
/// They live in `TransportEndDecision` (this tier) rather than on the tsnet
/// transport, because a test target that links the tsnet tier needs
/// `libtailscale.a`, which the linux-protocol job deliberately never builds.
///
/// Both decisions exist because their absence was a frozen frame forever: a
/// sharer that crashed without a BYE left the portable viewer ticking against
/// a silent socket, and a dead socket's recv errors were swallowed by a bare
/// `continue`. The live halves (the detached receive task, the run loop's
/// break) can only be exercised against a real node, which is the repo's
/// documented local-only constraint — so the decisions live here, extracted.
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
    /// the wait at the approval prompt must never time out — however long it
    /// takes. (The sharer prunes stale pending viewers on its own, longer
    /// clock; the viewer's Cancel is the way out on this side.)
    func testIdleSuppressedWhilePendingApproval() {
        XCTAssertFalse(
            TransportEndDecision.idleTimedOut(
                nowNs: 600_000_000_000, lastDatagramNs: 0, isPendingApproval: true,
                timeoutNs: 15_000_000_000))
    }

    /// The default threshold is the shared tuning constant, so the two ends of
    /// the wire (server sweep, viewer disconnect) stay designed to time out
    /// together.
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
    /// timeouts resets the consecutive counter forever, and would poll a sick
    /// socket for eternity without the trailing-window bound. Errors spaced a
    /// second apart with a benign timeout between each stay inside the 60 s
    /// window, so the `maxErrorsPerWindow`-th one still gives up.
    func testErrorTimeoutAlternationTripsTheWindowedBackstop() {
        var tally = TransportEndDecision.ReceiveFailureTally()
        var fatalAt: Int?
        for i in 1...ReceiveLoopPolicy.maxErrorsPerWindow {
            let nowNs = UInt64(i) * 1_000_000_000
            if TransportEndDecision.receiveFailureIsFatal(&tally, benignTimeout: false, nowNs: nowNs) {
                fatalAt = i
                break
            }
            // The interleaved timeout that keeps the consecutive counter at
            // zero — the exact pattern the backstop exists for.
            XCTAssertFalse(
                TransportEndDecision.receiveFailureIsFatal(
                    &tally, benignTimeout: true, nowNs: nowNs + 500_000_000))
        }
        XCTAssertEqual(
            fatalAt, ReceiveLoopPolicy.maxErrorsPerWindow,
            "the windowed backstop must fire on the \(ReceiveLoopPolicy.maxErrorsPerWindow)th error, consecutive resets notwithstanding"
        )
    }

    /// Stamps older than the window are pruned: a burst of errors an hour ago
    /// must not count against a socket that has been healthy since.
    func testOldErrorsAgeOutOfTheWindow() {
        var tally = TransportEndDecision.ReceiveFailureTally()
        // A near-fatal burst at t≈0, defused below the consecutive threshold
        // by a trailing benign timeout.
        for i in 1...(ReceiveLoopPolicy.maxErrorsPerWindow - 1) {
            _ = TransportEndDecision.receiveFailureIsFatal(
                &tally, benignTimeout: false, nowNs: UInt64(i) * 1_000)
            _ = TransportEndDecision.receiveFailureIsFatal(
                &tally, benignTimeout: true, nowNs: UInt64(i) * 1_000 + 500)
        }
        // One more error, a full window later: the old stamps are gone, so
        // this is error 1-of-30, not 30-of-30.
        let laterNs = ReceiveLoopPolicy.errorWindowNs * 2
        XCTAssertFalse(
            TransportEndDecision.receiveFailureIsFatal(&tally, benignTimeout: false, nowNs: laterNs))
        XCTAssertEqual(tally.errorStampsNs.count, 1, "aged-out stamps must be pruned")
    }
}
