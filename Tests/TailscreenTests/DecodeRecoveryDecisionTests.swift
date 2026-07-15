import XCTest

@testable import Tailscreen

/// Unit tests for the viewer's consecutive-decode-failure escalation ladder
/// (`VideoDecoder.decodeRecoveryAction`). Pure function, no VideoToolbox, no
/// tsnet — the live counter increments in +1 steps on the decoder's serial
/// queue and resets on the first successful frame, so exact-threshold
/// matching is what makes each rung fire once per failing episode. Same
/// pattern as `AdaptiveBitrateTests`.
final class DecodeRecoveryDecisionTests: XCTestCase {
    private func action(_ failures: Int) -> DecodeRecoveryAction? {
        VideoDecoder.decodeRecoveryAction(consecutiveFailures: failures)
    }

    func testRungsFireExactlyAtTheirThresholds() {
        XCTAssertEqual(action(VideoDecoder.requestKeyframeFailureThreshold), .requestKeyframe)
        XCTAssertEqual(action(VideoDecoder.recreateSessionFailureThreshold), .recreateSession)
        XCTAssertEqual(action(VideoDecoder.signalDegradedFailureThreshold), .signalDegraded)
        XCTAssertEqual(action(VideoDecoder.surfaceErrorFailureThreshold), .surfaceError)
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

    func testNoActionBetweenAndAroundThresholds() {
        for failures in [0, 1, 4, 6, 29, 31, 89, 91, 299, 301, 1000] {
            XCTAssertNil(action(failures), "expected no action at \(failures) failures")
        }
    }

    func testRungsEscalateInSeverityOrder() {
        XCTAssertLessThan(
            VideoDecoder.requestKeyframeFailureThreshold, VideoDecoder.recreateSessionFailureThreshold)
        XCTAssertLessThan(
            VideoDecoder.recreateSessionFailureThreshold, VideoDecoder.signalDegradedFailureThreshold)
        XCTAssertLessThan(
            VideoDecoder.signalDegradedFailureThreshold, VideoDecoder.surfaceErrorFailureThreshold)
    }

    func testFullEpisodeFiresEachRungExactlyOnce() {
        // Walk an entire failing episode (counter incrementing 1, 2, 3, …)
        // and confirm each rung fires exactly once and nothing fires past
        // the last one.
        var seen: [DecodeRecoveryAction: Int] = [:]
        for failures in 1...(VideoDecoder.surfaceErrorFailureThreshold + 100) {
            if let rung = action(failures) {
                seen[rung, default: 0] += 1
            }
        }
        let expected: [DecodeRecoveryAction: Int] = [
            .requestKeyframe: 1,
            .recreateSession: 1,
            .signalDegraded: 1,
            .surfaceError: 1
        ]
        XCTAssertEqual(seen, expected)
    }

    func testResetEpisodeStartsTheLadderOver() {
        // A successful frame resets the live counter to zero; the next
        // failing run must reach the first rung again.
        XCTAssertNil(action(0))
        XCTAssertNil(action(1))
        XCTAssertEqual(action(VideoDecoder.requestKeyframeFailureThreshold), .requestKeyframe)
    }
}
