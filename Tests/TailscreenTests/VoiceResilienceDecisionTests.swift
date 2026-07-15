import XCTest

@testable import Tailscreen

/// Unit tests for the voice-path resilience decisions. Pure functions, no
/// tsnet, no audio hardware — the extract-the-decision pattern from
/// `AdaptiveBitrateTests`. Covers the decoder-failure cooldown gate,
/// wrap-aware sequence-gap concealment, adaptive jitter-buffer sizing, the
/// clamp-log throttle, the single-pass clamp helper, idle-SSRC eviction,
/// the concealment emission cap and fade-out shape, the underrun
/// starve-then-resume verdict, the jitter-estimator pause detector, and
/// the stats change-detection compare.
final class VoiceResilienceDecisionTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    // MARK: - decoderGateAction

    private func record(failures: Int, lastNs: UInt64) -> VoiceChannel.DecoderFailureRecord {
        VoiceChannel.DecoderFailureRecord(consecutiveInitFailures: failures, lastFailureNs: lastNs)
    }

    func testAllowsWhenNoRecord() {
        XCTAssertEqual(VoiceChannel.decoderGateAction(record: nil, nowNs: 100 * s), .allow)
    }

    func testDropsInsideCooldown() {
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceChannel.decoderGateAction(record: rec, nowNs: 101 * s), .drop)
    }

    func testDropsExactlyAtCooldownBoundary() {
        // Cooldown must strictly elapse: `now - last > cooldown`.
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceChannel.decoderGateAction(record: rec, nowNs: 105 * s), .drop)
    }

    func testAllowsRetryAfterCooldown() {
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(
            VoiceChannel.decoderGateAction(record: rec, nowNs: 105 * s + 1), .allow)
    }

    func testDropsPermanentlyAfterFailureLimit() {
        let rec = record(failures: VoiceChannel.decoderInitFailureLimit, lastNs: 100 * s)
        // Even long after the cooldown, permanent means permanent.
        XCTAssertEqual(VoiceChannel.decoderGateAction(record: rec, nowNs: 10_000 * s), .drop)
    }

    func testOneBelowLimitStillRetries() {
        let rec = record(failures: VoiceChannel.decoderInitFailureLimit - 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceChannel.decoderGateAction(record: rec, nowNs: 200 * s), .allow)
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

    // MARK: - staleSSRCs

    func testNoEntriesNothingStale() {
        XCTAssertEqual(VoiceChannel.staleSSRCs(lastArrivalsNs: [:], nowNs: 100 * s), [])
    }

    func testFreshEntriesAreKept() {
        let arrivals: [UInt32: UInt64] = [1: 95 * s, 2: 99 * s]
        XCTAssertEqual(VoiceChannel.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [])
    }

    func testIdleEntriesAreEvictedSorted() {
        let arrivals: [UInt32: UInt64] = [7: 10 * s, 3: 20 * s, 5: 99 * s]
        XCTAssertEqual(VoiceChannel.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [3, 7])
    }

    func testIdleBoundaryIsExclusive() {
        // Staleness must strictly exceed the idle window (default 10 s).
        let arrivals: [UInt32: UInt64] = [1: 90 * s]
        XCTAssertEqual(VoiceChannel.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [])
        XCTAssertEqual(VoiceChannel.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s + 1), [1])
    }

    func testFutureArrivalIsNotStale() {
        // Clock-skew safety: an arrival stamped ahead of `now` must not
        // wrap into a huge idle time.
        let arrivals: [UInt32: UInt64] = [1: 200 * s]
        XCTAssertEqual(VoiceChannel.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [])
    }

    // MARK: - concealmentEmitCount

    func testConcealmentCapReservesARealFrameSlot() {
        // Default slack 3 → at most 2 silence frames per gap, so the fill
        // alone can never push the next real frame into an overrun drop.
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 1), 1)
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 2), 2)
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 3), 2)
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 5), 2)
    }

    func testConcealmentCapDegenerateInputs() {
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 0), 0)
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: -1), 0)
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 5, slackBuffers: 1), 0)
        XCTAssertEqual(VoiceChannel.concealmentEmitCount(missing: 5, slackBuffers: 0), 0)
    }

    // MARK: - concealmentFadeOut

    func testFadeOutRampsFromLastEmittedSample() {
        let frame = VoiceChannel.concealmentFadeOut(from: 1.0)
        XCTAssertEqual(frame.count, VoiceChannel.samplesPerFrame)
        // First sample continues from the last emitted one (one ramp step
        // below it), not from 63 samples back in time.
        XCTAssertEqual(frame[0], 1.0 - 1.0 / 64.0, accuracy: 1e-6)
        for i in 1..<VoiceChannel.fadeSampleCount {
            XCTAssertLessThan(frame[i], frame[i - 1], "fade-out must decrease monotonically")
        }
        XCTAssertEqual(frame[VoiceChannel.fadeSampleCount - 1], 0)
        XCTAssertTrue(frame[VoiceChannel.fadeSampleCount...].allSatisfy { $0 == 0 })
    }

    func testFadeOutFromNegativeSampleRampsUpTowardZero() {
        let frame = VoiceChannel.concealmentFadeOut(from: -0.5)
        XCTAssertEqual(frame[0], -0.5 * (1.0 - 1.0 / 64.0), accuracy: 1e-6)
        for i in 1..<VoiceChannel.fadeSampleCount {
            XCTAssertGreaterThan(frame[i], frame[i - 1], "fade toward zero from below")
        }
    }

    func testFadeOutFromSilenceIsAllZeros() {
        XCTAssertTrue(VoiceChannel.concealmentFadeOut(from: 0).allSatisfy { $0 == 0 })
    }

    // MARK: - isStarveResume

    func testDrainWithQuickResumeIsAnUnderrun() {
        XCTAssertTrue(VoiceChannel.isStarveResume(drainedAtNs: 100 * s, nowNs: 100 * s + s / 2))
    }

    func testDrainFollowedByLongSilenceIsBenign() {
        // Mute / end-of-stream / teardown: the queue legitimately drains.
        XCTAssertFalse(VoiceChannel.isStarveResume(drainedAtNs: 100 * s, nowNs: 102 * s))
    }

    func testResumeWindowBoundaryIsExclusive() {
        XCTAssertFalse(VoiceChannel.isStarveResume(drainedAtNs: 100 * s, nowNs: 101 * s))
        XCTAssertTrue(VoiceChannel.isStarveResume(drainedAtNs: 100 * s, nowNs: 101 * s - 1))
    }

    func testNoPendingDrainIsNotAnUnderrun() {
        XCTAssertFalse(VoiceChannel.isStarveResume(drainedAtNs: 0, nowNs: 100 * s))
    }

    // MARK: - isPauseDeviation

    func testOrdinaryJitterIsNotAPause() {
        XCTAssertFalse(VoiceChannel.isPauseDeviation(deviationMs: 0))
        XCTAssertFalse(VoiceChannel.isPauseDeviation(deviationMs: 80))
        XCTAssertFalse(VoiceChannel.isPauseDeviation(deviationMs: 500))
    }

    func testPauseSizedDeviationIsAPause() {
        XCTAssertTrue(VoiceChannel.isPauseDeviation(deviationMs: 500.1))
        XCTAssertTrue(VoiceChannel.isPauseDeviation(deviationMs: 30_000))
    }

    // MARK: - VoiceStats.countersDiffer

    func testJitterOnlyChangeDoesNotCountAsDiffer() {
        var stats = VoiceStats()
        stats.smoothedJitterMs = 42
        XCTAssertFalse(stats.countersDiffer(from: VoiceStats()))
        XCTAssertFalse(VoiceStats().countersDiffer(from: stats))
    }

    func testEqualStatsDoNotDiffer() {
        XCTAssertFalse(VoiceStats().countersDiffer(from: VoiceStats()))
    }

    func testEachCounterChangeCountsAsDiffer() {
        let mutations: [(String, (inout VoiceStats) -> Void)] = [
            ("overrunDrops", { $0.overrunDrops += 1 }),
            ("underruns", { $0.underruns += 1 }),
            ("concealedFrames", { $0.concealedFrames += 1 }),
            ("discontinuities", { $0.discontinuities += 1 }),
            ("clampedBuffers", { $0.clampedBuffers += 1 })
        ]
        for (name, mutate) in mutations {
            var stats = VoiceStats()
            mutate(&stats)
            XCTAssertTrue(stats.countersDiffer(from: VoiceStats()), "\(name) must register a change")
        }
    }
}
