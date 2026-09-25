import TailscreenViewer
import XCTest

/// Tests for the viewer's consecutive-decode-failure escalation ladder
/// (`DecodeRecovery.action`). Pure function; live counters increment on each
/// host's decode path and reset on the first successful frame. Rungs fire on
/// `>=` thresholds with a per-episode fired-rung latch, so each rung fires
/// once per failing episode even if a threshold value gets skipped. Plain
/// (non-`@testable`) import — the decision surface is deliberately public.
final class DecodeRecoveryDecisionTests: XCTestCase {
    private func action(
        _ failures: Int, fired: Set<DecodeRecoveryAction> = []
    ) -> DecodeRecoveryAction? {
        DecodeRecovery.action(consecutiveFailures: failures, alreadyFired: fired)
    }

    /// Walk a failing episode the way the decoder does: bump the counter by
    /// `step`, ask for an action, latch whatever fired. Returns the actions
    /// in firing order.
    private func runEpisode(step: Int, upTo limit: Int) -> [DecodeRecoveryAction] {
        var fired: Set<DecodeRecoveryAction> = []
        var seen: [DecodeRecoveryAction] = []
        var count = 0
        while count < limit {
            count += step
            if let rung = action(count, fired: fired) {
                fired.insert(rung)
                seen.append(rung)
            }
        }
        return seen
    }

    func testRungsFireAtTheirThresholds() {
        XCTAssertEqual(action(DecodeRecovery.requestKeyframeFailureThreshold), .requestKeyframe)
        XCTAssertEqual(
            action(DecodeRecovery.recreateSessionFailureThreshold, fired: [.requestKeyframe]),
            .recreateSession)
        XCTAssertEqual(
            action(
                DecodeRecovery.signalDegradedFailureThreshold,
                fired: [.requestKeyframe, .recreateSession]),
            .signalDegraded)
        XCTAssertEqual(
            action(
                DecodeRecovery.surfaceErrorFailureThreshold,
                fired: [.requestKeyframe, .recreateSession, .signalDegraded]),
            .surfaceError)
    }

    func testDocumentedThresholdValues() {
        // Ladder timing (PLI ~5 frames, alert after ~5-10s dead video)
        // depends on these exact values.
        XCTAssertEqual(DecodeRecovery.requestKeyframeFailureThreshold, 5)
        XCTAssertEqual(DecodeRecovery.recreateSessionFailureThreshold, 30)
        XCTAssertEqual(DecodeRecovery.signalDegradedFailureThreshold, 90)
        XCTAssertEqual(DecodeRecovery.surfaceErrorFailureThreshold, 300)
    }

    func testNoActionBelowTheFirstThreshold() {
        for failures in 0..<DecodeRecovery.requestKeyframeFailureThreshold {
            XCTAssertNil(action(failures), "expected no action at \(failures) failures")
        }
    }

    func testEachRungFiresOncePerEpisode() {
        XCTAssertEqual(action(5), .requestKeyframe)
        XCTAssertNil(action(6, fired: [.requestKeyframe]))
        XCTAssertNil(action(29, fired: [.requestKeyframe]))
        XCTAssertNil(action(91, fired: [.requestKeyframe, .recreateSession, .signalDegraded]))
        let all: Set<DecodeRecoveryAction> = [
            .requestKeyframe, .recreateSession, .signalDegraded, .surfaceError
        ]
        XCTAssertNil(action(301, fired: all))
        XCTAssertNil(action(100_000, fired: all))
    }

    func testThresholdsTolerateSkippedCounts() {
        // `>=` matching: a counter that jumps past the threshold still fires.
        XCTAssertEqual(action(6), .requestKeyframe)
        XCTAssertEqual(action(31, fired: [.requestKeyframe]), .recreateSession)
        XCTAssertEqual(action(92, fired: [.requestKeyframe, .recreateSession]), .signalDegraded)
        XCTAssertEqual(
            action(305, fired: [.requestKeyframe, .recreateSession, .signalDegraded]),
            .surfaceError)
    }

    func testJumpFiresTheHighestMetRungAndSupersedesLowerOnes() {
        // Skipped lower rungs never fire late and out of order.
        XCTAssertEqual(action(100), .signalDegraded)
        XCTAssertNil(action(101, fired: [.signalDegraded]))
        XCTAssertEqual(action(300, fired: [.signalDegraded]), .surfaceError)
    }

    func testFullEpisodeFiresEachRungExactlyOnceInOrder() {
        let expected: [DecodeRecoveryAction] = [
            .requestKeyframe, .recreateSession, .signalDegraded, .surfaceError
        ]
        XCTAssertEqual(runEpisode(step: 1, upTo: DecodeRecovery.surfaceErrorFailureThreshold + 100), expected)
    }

    func testPlusTwoSteppedEpisodeStillFiresEachRungOnceInOrder() {
        // A counter that only lands on even values (missing every odd
        // threshold) still walks all four rungs once each via `>=` + latch.
        let expected: [DecodeRecoveryAction] = [
            .requestKeyframe, .recreateSession, .signalDegraded, .surfaceError
        ]
        XCTAssertEqual(runEpisode(step: 2, upTo: DecodeRecovery.surfaceErrorFailureThreshold + 100), expected)
    }

    func testRungsEscalateInSeverityOrder() {
        XCTAssertLessThan(
            DecodeRecovery.requestKeyframeFailureThreshold, DecodeRecovery.recreateSessionFailureThreshold)
        XCTAssertLessThan(
            DecodeRecovery.recreateSessionFailureThreshold, DecodeRecovery.signalDegradedFailureThreshold)
        XCTAssertLessThan(
            DecodeRecovery.signalDegradedFailureThreshold, DecodeRecovery.surfaceErrorFailureThreshold)
    }

    func testResetEpisodeStartsTheLadderOver() {
        // A successful frame resets the counter and clears fired-rung latches.
        XCTAssertNil(action(0))
        XCTAssertNil(action(1))
        XCTAssertEqual(action(DecodeRecovery.requestKeyframeFailureThreshold), .requestKeyframe)
    }
}
