import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// Unit tests for the voice-path resilience decisions
/// (`VoiceReceiveDecisions`, extracted from the macOS `VoiceChannel` and now
/// shared with `VoiceDownlink`). Pure functions, no tsnet, no audio hardware —
/// the extract-the-decision pattern from `AdaptiveBitrateTests`. Covers the
/// payload-type demux, the decoder-failure cooldown gate, wrap-aware
/// sequence-gap concealment, adaptive jitter-buffer sizing, the clamp-log
/// throttle, the single-pass clamp helper, idle-SSRC eviction, the
/// concealment emission cap and fade-out shape, the underrun
/// starve-then-resume verdict, the jitter-estimator pause detector, and
/// the stats change-detection compare.
final class VoiceResilienceDecisionTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    // MARK: - audioRoute

    func testVoicePayloadTypeRoutesToVoice() {
        XCTAssertEqual(
            VoiceReceiveDecisions.audioRoute(payloadType: RTPHeader.voicePayloadType), .voice)
    }

    func testSystemAudioPayloadTypeRoutesToSystemAudio() {
        XCTAssertEqual(
            VoiceReceiveDecisions.audioRoute(payloadType: RTPHeader.systemAudioPayloadType),
            .systemAudio)
    }

    func testVideoPayloadTypesDrop() {
        XCTAssertEqual(VoiceReceiveDecisions.audioRoute(payloadType: RTPHeader.h264PayloadType), .drop)
        XCTAssertEqual(VoiceReceiveDecisions.audioRoute(payloadType: RTPHeader.hevcPayloadType), .drop)
        XCTAssertEqual(VoiceReceiveDecisions.audioRoute(payloadType: 200), .drop)
    }

    // MARK: - decoderGateAction

    private func record(failures: Int, lastNs: UInt64) -> VoiceReceiveDecisions.DecoderFailureRecord {
        VoiceReceiveDecisions.DecoderFailureRecord(
            consecutiveInitFailures: failures, lastFailureNs: lastNs)
    }

    func testAllowsWhenNoRecord() {
        XCTAssertEqual(VoiceReceiveDecisions.decoderGateAction(record: nil, nowNs: 100 * s), .allow)
    }

    func testDropsInsideCooldown() {
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceReceiveDecisions.decoderGateAction(record: rec, nowNs: 101 * s), .drop)
    }

    func testDropsExactlyAtCooldownBoundary() {
        // Cooldown must strictly elapse: `now - last > cooldown`.
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceReceiveDecisions.decoderGateAction(record: rec, nowNs: 105 * s), .drop)
    }

    func testAllowsRetryAfterCooldown() {
        let rec = record(failures: 1, lastNs: 100 * s)
        XCTAssertEqual(
            VoiceReceiveDecisions.decoderGateAction(record: rec, nowNs: 105 * s + 1), .allow)
    }

    func testDropsPermanentlyAfterFailureLimit() {
        let rec = record(failures: VoiceReceiveDecisions.decoderInitFailureLimit, lastNs: 100 * s)
        // Even long after the cooldown, permanent means permanent.
        XCTAssertEqual(VoiceReceiveDecisions.decoderGateAction(record: rec, nowNs: 10_000 * s), .drop)
    }

    func testOneBelowLimitStillRetries() {
        let rec = record(failures: VoiceReceiveDecisions.decoderInitFailureLimit - 1, lastNs: 100 * s)
        XCTAssertEqual(VoiceReceiveDecisions.decoderGateAction(record: rec, nowNs: 200 * s), .allow)
    }

    // MARK: - gapAction

    func testFirstPacketAlwaysDecodes() {
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: nil, newSeq: 12345), .decode)
    }

    func testInOrderDecodes() {
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: 10, newSeq: 11), .decode)
    }

    func testDuplicateIsStale() {
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: 10, newSeq: 10), .dropStale)
    }

    func testReorderedLateIsStale() {
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: 10, newSeq: 7), .dropStale)
    }

    func testSmallGapsConceal() {
        for gap in 1...5 {
            XCTAssertEqual(
                VoiceReceiveDecisions.gapAction(lastSeq: 10, newSeq: UInt16(11 + gap)),
                .concealThenDecode(missing: gap),
                "gap of \(gap) should be concealed")
        }
    }

    func testGapBeyondCapIsDiscontinuity() {
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: 10, newSeq: 17), .discontinuity)
    }

    func testWraparoundInOrder() {
        // Mirrors RTPAudioTests.testSequenceWraparound: 0xFFFF → 0x0000.
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: 0xFFFF, newSeq: 0x0000), .decode)
    }

    func testWraparoundGapConceals() {
        // 0xFFFE received; 0xFFFF, 0x0000, 0x0001 lost; 0x0002 arrives.
        XCTAssertEqual(
            VoiceReceiveDecisions.gapAction(lastSeq: 0xFFFE, newSeq: 0x0002),
            .concealThenDecode(missing: 3))
    }

    func testWraparoundLateIsStale() {
        XCTAssertEqual(VoiceReceiveDecisions.gapAction(lastSeq: 0x0001, newSeq: 0xFFFE), .dropStale)
    }

    // MARK: - jitterBufferTarget

    func testCalmJitterStepsDownTowardMin() {
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 0, currentTarget: 3), 2)
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 0, currentTarget: 2), 2)
    }

    func testHighJitterStepsUpByOne() {
        // 100 ms of jitter wants ~6 buffers of slack, but growth is bounded
        // to one step per call.
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 100, currentTarget: 3), 4)
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 100, currentTarget: 4), 5)
    }

    func testTargetClampsAtMaxDepth() {
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 10_000, currentTarget: 12), 12)
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 10_000, currentTarget: 11), 12)
    }

    func testTargetHoldsWhenIdealMatches() {
        // ~30 ms of jitter → ceil(30 / 21.33) = 2 slack + 1 base = 3.
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 30, currentTarget: 3), 3)
    }

    func testTargetMonotoneInJitter() {
        var previous = 0
        for jitterMs in stride(from: 0.0, through: 300.0, by: 10.0) {
            let target = VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: jitterMs, currentTarget: 7)
            XCTAssertGreaterThanOrEqual(target, previous, "target must not shrink as jitter grows")
            previous = target
        }
    }

    // MARK: - shouldLogClamp

    func testClampLogSilentBelowThreshold() {
        for count in 0..<50 {
            XCTAssertFalse(VoiceReceiveDecisions.shouldLogClamp(count: count))
        }
    }

    func testClampLogFiresAtThresholdCrossing() {
        XCTAssertTrue(VoiceReceiveDecisions.shouldLogClamp(count: 50))
        XCTAssertFalse(VoiceReceiveDecisions.shouldLogClamp(count: 51))
    }

    func testClampLogFiresEveryModuloAfterThreshold() {
        XCTAssertTrue(VoiceReceiveDecisions.shouldLogClamp(count: 1000))
        XCTAssertFalse(VoiceReceiveDecisions.shouldLogClamp(count: 1001))
        XCTAssertTrue(VoiceReceiveDecisions.shouldLogClamp(count: 2000))
    }

    // MARK: - clampToUnitRange

    func testClampLeavesInRangeSamplesUntouched() {
        var samples: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
        let original = samples
        XCTAssertFalse(VoiceReceiveDecisions.clampToUnitRange(&samples))
        XCTAssertEqual(samples, original)
    }

    func testClampFlagsAndClampsOutOfRangeSamples() {
        var samples: [Float] = [-6.0, -0.5, 0.5, 6.0]
        XCTAssertTrue(VoiceReceiveDecisions.clampToUnitRange(&samples))
        XCTAssertEqual(samples, [-1.0, -0.5, 0.5, 1.0])
    }

    // MARK: - staleSSRCs

    func testNoEntriesNothingStale() {
        XCTAssertEqual(VoiceReceiveDecisions.staleSSRCs(lastArrivalsNs: [:], nowNs: 100 * s), [])
    }

    func testFreshEntriesAreKept() {
        let arrivals: [UInt32: UInt64] = [1: 95 * s, 2: 99 * s]
        XCTAssertEqual(VoiceReceiveDecisions.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [])
    }

    func testIdleEntriesAreEvictedSorted() {
        let arrivals: [UInt32: UInt64] = [7: 10 * s, 3: 20 * s, 5: 99 * s]
        XCTAssertEqual(VoiceReceiveDecisions.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [3, 7])
    }

    func testIdleBoundaryIsExclusive() {
        // Staleness must strictly exceed the idle window (default 10 s).
        let arrivals: [UInt32: UInt64] = [1: 90 * s]
        XCTAssertEqual(VoiceReceiveDecisions.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [])
        XCTAssertEqual(VoiceReceiveDecisions.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s + 1), [1])
    }

    func testFutureArrivalIsNotStale() {
        // Clock-skew safety: an arrival stamped ahead of `now` must not
        // wrap into a huge idle time.
        let arrivals: [UInt32: UInt64] = [1: 200 * s]
        XCTAssertEqual(VoiceReceiveDecisions.staleSSRCs(lastArrivalsNs: arrivals, nowNs: 100 * s), [])
    }

    // MARK: - concealmentEmitCount

    func testConcealmentCapReservesARealFrameSlot() {
        // Default slack 3 → at most 2 silence frames per gap, so the fill
        // alone can never push the next real frame into an overrun drop.
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 1), 1)
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 2), 2)
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 3), 2)
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 5), 2)
    }

    func testConcealmentCapDegenerateInputs() {
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 0), 0)
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: -1), 0)
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 5, slackBuffers: 1), 0)
        XCTAssertEqual(VoiceReceiveDecisions.concealmentEmitCount(missing: 5, slackBuffers: 0), 0)
    }

    // MARK: - concealmentFadeOut

    func testFadeOutRampsFromLastEmittedSample() {
        let frame = VoiceReceiveDecisions.concealmentFadeOut(from: 1.0)
        XCTAssertEqual(frame.count, VoiceReceiveDecisions.samplesPerFrame)
        // First sample continues from the last emitted one (one ramp step
        // below it), not from 63 samples back in time.
        XCTAssertEqual(frame[0], 1.0 - 1.0 / 64.0, accuracy: 1e-6)
        for i in 1..<VoiceReceiveDecisions.fadeSampleCount {
            XCTAssertLessThan(frame[i], frame[i - 1], "fade-out must decrease monotonically")
        }
        XCTAssertEqual(frame[VoiceReceiveDecisions.fadeSampleCount - 1], 0)
        XCTAssertTrue(frame[VoiceReceiveDecisions.fadeSampleCount...].allSatisfy { $0 == 0 })
    }

    func testFadeOutFromNegativeSampleRampsUpTowardZero() {
        let frame = VoiceReceiveDecisions.concealmentFadeOut(from: -0.5)
        XCTAssertEqual(frame[0], -0.5 * (1.0 - 1.0 / 64.0), accuracy: 1e-6)
        for i in 1..<VoiceReceiveDecisions.fadeSampleCount {
            XCTAssertGreaterThan(frame[i], frame[i - 1], "fade toward zero from below")
        }
    }

    func testFadeOutFromSilenceIsAllZeros() {
        XCTAssertTrue(VoiceReceiveDecisions.concealmentFadeOut(from: 0).allSatisfy { $0 == 0 })
    }

    // MARK: - isStarveResume

    func testDrainWithQuickResumeIsAnUnderrun() {
        XCTAssertTrue(VoiceReceiveDecisions.isStarveResume(drainedAtNs: 100 * s, nowNs: 100 * s + s / 2))
    }

    func testDrainFollowedByLongSilenceIsBenign() {
        // Mute / end-of-stream / teardown: the queue legitimately drains.
        XCTAssertFalse(VoiceReceiveDecisions.isStarveResume(drainedAtNs: 100 * s, nowNs: 102 * s))
    }

    func testResumeWindowBoundaryIsExclusive() {
        XCTAssertFalse(VoiceReceiveDecisions.isStarveResume(drainedAtNs: 100 * s, nowNs: 101 * s))
        XCTAssertTrue(VoiceReceiveDecisions.isStarveResume(drainedAtNs: 100 * s, nowNs: 101 * s - 1))
    }

    func testNoPendingDrainIsNotAnUnderrun() {
        XCTAssertFalse(VoiceReceiveDecisions.isStarveResume(drainedAtNs: 0, nowNs: 100 * s))
    }

    // MARK: - isPauseDeviation

    func testOrdinaryJitterIsNotAPause() {
        XCTAssertFalse(VoiceReceiveDecisions.isPauseDeviation(deviationMs: 0))
        XCTAssertFalse(VoiceReceiveDecisions.isPauseDeviation(deviationMs: 80))
        XCTAssertFalse(VoiceReceiveDecisions.isPauseDeviation(deviationMs: 500))
    }

    func testPauseSizedDeviationIsAPause() {
        XCTAssertTrue(VoiceReceiveDecisions.isPauseDeviation(deviationMs: 500.1))
        XCTAssertTrue(VoiceReceiveDecisions.isPauseDeviation(deviationMs: 30_000))
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
