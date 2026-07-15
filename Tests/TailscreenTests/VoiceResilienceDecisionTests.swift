import XCTest

@testable import Tailscreen

/// Unit tests for the voice-path resilience decisions. Pure functions, no
/// tsnet, no audio hardware — the extract-the-decision pattern from
/// `AdaptiveBitrateTests`. Covers the decoder-failure cooldown blacklist,
/// wrap-aware sequence-gap concealment, adaptive jitter-buffer sizing, the
/// clamp-log throttle, and the single-pass clamp helper.
final class VoiceResilienceDecisionTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    // MARK: - blacklistAction

    private func record(failures: Int, lastNs: UInt64) -> VoiceChannel.DecoderFailureRecord {
        VoiceChannel.DecoderFailureRecord(consecutiveInitFailures: failures, lastFailureNs: lastNs)
    }

    func testAllowsWhenNoRecord() {
        XCTAssertEqual(VoiceChannel.blacklistAction(record: nil, nowNs: 100 * s), .allow)
    }

    func testDropsInsideCooldown() {
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceChannel.blacklistAction(record: rec, nowNs: 101 * s), .drop)
    }

    func testDropsExactlyAtCooldownBoundary() {
        // Cooldown must strictly elapse: `now - last > cooldown`.
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceChannel.blacklistAction(record: rec, nowNs: 105 * s), .drop)
    }

    func testAllowsRetryAfterCooldown() {
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(
            VoiceChannel.blacklistAction(record: rec, nowNs: 105 * s + 1), .allow)
    }

    func testDropsPermanentlyAfterFailureLimit() {
        let rec = record(failures: VoiceChannel.decoderInitFailureLimit, lastNs: 100 * s)
        // Even long after the cooldown, permanent means permanent.
        XCTAssertEqual(VoiceChannel.blacklistAction(record: rec, nowNs: 10_000 * s), .drop)
    }

    func testOneBelowLimitStillRetries() {
        let rec = record(failures: VoiceChannel.decoderInitFailureLimit - 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceChannel.blacklistAction(record: rec, nowNs: 200 * s), .allow)
    }

    // MARK: - gapAction

    func testFirstPacketAlwaysDecodes() {
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: nil, newSeq: 12345), .decode)
    }

    func testInOrderDecodes() {
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: 10, newSeq: 11), .decode)
    }

    func testDuplicateIsStale() {
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: 10, newSeq: 10), .dropStale)
    }

    func testReorderedLateIsStale() {
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: 10, newSeq: 7), .dropStale)
    }

    func testSmallGapsConceal() {
        for gap in 1...5 {
            XCTAssertEqual(
                VoiceChannel.gapAction(lastSeq: 10, newSeq: UInt16(11 + gap)),
                .concealThenDecode(missing: gap),
                "gap of \(gap) should be concealed")
        }
    }

    func testGapBeyondCapIsDiscontinuity() {
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: 10, newSeq: 17), .discontinuity)
    }

    func testWraparoundInOrder() {
        // Mirrors RTPAudioTests.testSequenceWraparound: 0xFFFF → 0x0000.
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: 0xFFFF, newSeq: 0x0000), .decode)
    }

    func testWraparoundGapConceals() {
        // 0xFFFE received; 0xFFFF, 0x0000, 0x0001 lost; 0x0002 arrives.
        XCTAssertEqual(
            VoiceChannel.gapAction(lastSeq: 0xFFFE, newSeq: 0x0002),
            .concealThenDecode(missing: 3))
    }

    func testWraparoundLateIsStale() {
        XCTAssertEqual(VoiceChannel.gapAction(lastSeq: 0x0001, newSeq: 0xFFFE), .dropStale)
    }

    // MARK: - jitterBufferTarget

    func testCalmJitterStepsDownTowardMin() {
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 0, currentTarget: 3), 2)
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 0, currentTarget: 2), 2)
    }

    func testHighJitterStepsUpByOne() {
        // 100 ms of jitter wants ~6 buffers of slack, but growth is bounded
        // to one step per call.
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 100, currentTarget: 3), 4)
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 100, currentTarget: 4), 5)
    }

    func testTargetClampsAtMaxDepth() {
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 10_000, currentTarget: 12), 12)
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 10_000, currentTarget: 11), 12)
    }

    func testTargetHoldsWhenIdealMatches() {
        // ~30 ms of jitter → ceil(30 / 21.33) = 2 slack + 1 base = 3.
        XCTAssertEqual(VoiceChannel.jitterBufferTarget(smoothedJitterMs: 30, currentTarget: 3), 3)
    }

    func testTargetMonotoneInJitter() {
        var previous = 0
        for jitterMs in stride(from: 0.0, through: 300.0, by: 10.0) {
            let target = VoiceChannel.jitterBufferTarget(smoothedJitterMs: jitterMs, currentTarget: 7)
            XCTAssertGreaterThanOrEqual(target, previous, "target must not shrink as jitter grows")
            previous = target
        }
    }

    // MARK: - shouldLogClamp

    func testClampLogSilentBelowThreshold() {
        for count in 0..<50 {
            XCTAssertFalse(VoiceChannel.shouldLogClamp(count: count))
        }
    }

    func testClampLogFiresAtThresholdCrossing() {
        XCTAssertTrue(VoiceChannel.shouldLogClamp(count: 50))
        XCTAssertFalse(VoiceChannel.shouldLogClamp(count: 51))
    }

    func testClampLogFiresEveryModuloAfterThreshold() {
        XCTAssertTrue(VoiceChannel.shouldLogClamp(count: 1000))
        XCTAssertFalse(VoiceChannel.shouldLogClamp(count: 1001))
        XCTAssertTrue(VoiceChannel.shouldLogClamp(count: 2000))
    }

    // MARK: - clampToUnitRange

    func testClampLeavesInRangeSamplesUntouched() {
        var samples: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
        let original = samples
        XCTAssertFalse(VoiceChannel.clampToUnitRange(&samples))
        XCTAssertEqual(samples, original)
    }

    func testClampFlagsAndClampsOutOfRangeSamples() {
        var samples: [Float] = [-6.0, -0.5, 0.5, 6.0]
        XCTAssertTrue(VoiceChannel.clampToUnitRange(&samples))
        XCTAssertEqual(samples, [-1.0, -0.5, 0.5, 1.0])
    }
}
