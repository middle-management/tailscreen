import TailscreenViewer
import XCTest

/// Unit tests for the viewer's consecutive-decode-failure escalation ladder
/// (`DecodeRecovery.action`). Pure function, no decoder, no tsnet — the live
/// counters increment on each host's decode path (the mac `VideoDecoder`'s
/// serial queue, or `ViewerSession` for the FFmpeg-backed hosts) and reset on
/// the first successful frame. Rungs fire on `>=` thresholds with a
/// per-episode fired-rung latch, so each rung fires once per failing episode
/// even when the counting is imperfect and a threshold value gets skipped.
/// Same pattern as `AdaptiveBitrateTests`. Moved here from the macOS app
/// target when the ladder went portable; a plain (non-`@testable`) import on
/// purpose — the decision surface is deliberately public, like the sharer
/// tier's.
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
        // The ladder's timing story (PLI at ~5 frames, alert after ~5-10 s
        // of dead video) depends on these exact values; changing them should
        // be a conscious decision.
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
        // A rung that already fired stays quiet while the count keeps
        // climbing toward the next threshold.
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
        // `>=` matching: a counter that jumps past the exact threshold value
        // (imperfect counting, +2 steps) still fires the rung.
        XCTAssertEqual(action(6), .requestKeyframe)
        XCTAssertEqual(action(31, fired: [.requestKeyframe]), .recreateSession)
        XCTAssertEqual(action(92, fired: [.requestKeyframe, .recreateSession]), .signalDegraded)
        XCTAssertEqual(
            action(305, fired: [.requestKeyframe, .recreateSession, .signalDegraded]),
            .surfaceError)
    }

    func testJumpFiresTheHighestMetRungAndSupersedesLowerOnes() {
        // A big jump fires the highest rung whose threshold is met; the
        // skipped lower rungs never fire late and out of order.
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
        // A counter that only ever lands on even values (e.g. a failure path
        // that double-counts) misses every odd threshold — the `>=` + latch
        // combination still walks all four rungs, in order, once each.
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
        // A successful frame resets the live counter to zero AND clears the
        // fired-rung latches; the next failing run reaches the first rung
        // again with an empty latch set.
        XCTAssertNil(action(0))
        XCTAssertNil(action(1))
        XCTAssertEqual(action(DecodeRecovery.requestKeyframeFailureThreshold), .requestKeyframe)
    }
}
