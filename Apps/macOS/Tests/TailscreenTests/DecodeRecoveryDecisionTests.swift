import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Unit tests for the viewer's consecutive-decode-failure escalation ladder
/// (`VideoDecoder.decodeRecoveryAction`). Pure function, no VideoToolbox, no
/// tsnet — the live counter increments on the decoder's serial queue and
/// resets on the first successful frame. Rungs fire on `>=` thresholds with
/// a per-episode fired-rung latch, so each rung fires once per failing
/// episode even when the counting is imperfect and a threshold value gets
/// skipped. Same pattern as `AdaptiveBitrateTests`.
final class DecodeRecoveryDecisionTests: XCTestCase {
    private func action(
        _ failures: Int, fired: Set<DecodeRecoveryAction> = []
    ) -> DecodeRecoveryAction? {
        VideoDecoder.decodeRecoveryAction(consecutiveFailures: failures, alreadyFired: fired)
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
        XCTAssertEqual(action(VideoDecoder.requestKeyframeFailureThreshold), .requestKeyframe)
        XCTAssertEqual(
            action(VideoDecoder.recreateSessionFailureThreshold, fired: [.requestKeyframe]),
            .recreateSession)
        XCTAssertEqual(
            action(
                VideoDecoder.signalDegradedFailureThreshold,
                fired: [.requestKeyframe, .recreateSession]),
            .signalDegraded)
        XCTAssertEqual(
            action(
                VideoDecoder.surfaceErrorFailureThreshold,
                fired: [.requestKeyframe, .recreateSession, .signalDegraded]),
            .surfaceError)
    }

    func testDocumentedThresholdValues() {
        // The ladder's timing story (PLI at ~5 frames, alert after ~5-10 s
        // of dead video) depends on these exact values; changing them should
        // be a conscious decision.
        XCTAssertEqual(VideoDecoder.requestKeyframeFailureThreshold, 5)
        XCTAssertEqual(VideoDecoder.recreateSessionFailureThreshold, 30)
        XCTAssertEqual(VideoDecoder.signalDegradedFailureThreshold, 90)
        XCTAssertEqual(VideoDecoder.surfaceErrorFailureThreshold, 300)
    }

    func testNoActionBelowTheFirstThreshold() {
        for failures in 0..<VideoDecoder.requestKeyframeFailureThreshold {
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
        XCTAssertEqual(runEpisode(step: 1, upTo: VideoDecoder.surfaceErrorFailureThreshold + 100), expected)
    }

    func testPlusTwoSteppedEpisodeStillFiresEachRungOnceInOrder() {
        // A counter that only ever lands on even values (e.g. a failure path
        // that double-counts) misses every odd threshold — the `>=` + latch
        // combination still walks all four rungs, in order, once each.
        let expected: [DecodeRecoveryAction] = [
            .requestKeyframe, .recreateSession, .signalDegraded, .surfaceError
        ]
        XCTAssertEqual(runEpisode(step: 2, upTo: VideoDecoder.surfaceErrorFailureThreshold + 100), expected)
    }

    func testRungsEscalateInSeverityOrder() {
        XCTAssertLessThan(
            VideoDecoder.requestKeyframeFailureThreshold, VideoDecoder.recreateSessionFailureThreshold)
        XCTAssertLessThan(
            VideoDecoder.recreateSessionFailureThreshold, VideoDecoder.signalDegradedFailureThreshold)
        XCTAssertLessThan(
            VideoDecoder.signalDegradedFailureThreshold, VideoDecoder.surfaceErrorFailureThreshold)
    }

    func testResetEpisodeStartsTheLadderOver() {
        // A successful frame resets the live counter to zero AND clears the
        // fired-rung latches; the next failing run reaches the first rung
        // again with an empty latch set.
        XCTAssertNil(action(0))
        XCTAssertNil(action(1))
        XCTAssertEqual(action(VideoDecoder.requestKeyframeFailureThreshold), .requestKeyframe)
    }
}
