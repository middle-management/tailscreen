import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// Pure-function tests for `VoiceReceiveDecisions` (shared by `VoiceChannel`
/// and `VoiceDownlink`): payload-type demux, decoder-failure cooldown,
/// wrap-aware gap concealment, jitter-buffer sizing, clamp/eviction/fade-out
/// helpers, underrun and pause detection, stats change-detection.
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

    /// Growth goes straight to the ideal; shrink is one step. The asymmetry
    /// is the point: being too shallow costs dropped audio every frame until
    /// the target catches up, and at a ~1 Hz sweep one-step growth spends
    /// nine more seconds dropping on the way from 3 to 12. Being too deep
    /// costs latency the next shrink gives back.
    func testGrowthIsImmediateAndShrinkIsOneStep() {
        // 100 ms of jitter wants ceil(100/20) + 1 = 6 buffers.
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 100, currentTarget: 3), 6)
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 100, currentTarget: 5), 6)
        // Coming back down from a deep buffer is gradual, so one quiet
        // window cannot collapse a buffer the path still needs.
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 0, currentTarget: 12), 11)
    }

    // MARK: - Sizing on burst depth

    /// The reason this parameter exists. These are the real readings from a
    /// 0.10.0-rc.16 sharer bundle: smoothed jitter between 32 and 39 ms for
    /// two minutes, which asks for a target of 3 — and 3 is exactly where the
    /// target sat while the receiver dropped 9 % of the frames it had been
    /// handed and starved 327 times. The burst reading is what the queue
    /// actually needed.
    func testSmoothedJitterAloneUnderSizesABurstyPath() {
        let jitterOnly = VoiceReceiveDecisions.jitterBufferTarget(
            smoothedJitterMs: 34.8, currentTarget: 3)
        XCTAssertEqual(jitterOnly, 3, "this is the rc.16 behaviour, kept as the baseline")

        let withBurst = VoiceReceiveDecisions.jitterBufferTarget(
            smoothedJitterMs: 34.8, burstDepth: 15, currentTarget: 3)
        XCTAssertGreaterThan(
            withBurst, jitterOnly,
            "a 15-frame burst must size the buffer, and smoothed jitter never sees it")
        XCTAssertEqual(withBurst, 12, "clamped at maxDepth")
    }

    /// And it is self-limiting: a path that does not burst keeps today's
    /// buffer and today's latency. Without this the fix would be "add 240 ms
    /// of delay to every call" rather than "to the calls that need it".
    func testACleanPathKeepsTheJitterDerivedTarget() {
        XCTAssertEqual(
            VoiceReceiveDecisions.jitterBufferTarget(
                smoothedJitterMs: 5, burstDepth: 1, currentTarget: 2),
            2)
        XCTAssertEqual(
            VoiceReceiveDecisions.jitterBufferTarget(
                smoothedJitterMs: 30, burstDepth: 2, currentTarget: 3),
            3)
    }

    /// The deeper of the two readings wins, in both directions — neither
    /// input may mask the other.
    func testTargetTakesTheDeeperOfJitterAndBurst() {
        // Jitter wants 6, burst saw 2 → 6.
        XCTAssertEqual(
            VoiceReceiveDecisions.jitterBufferTarget(
                smoothedJitterMs: 100, burstDepth: 2, currentTarget: 2),
            6)
        // Jitter wants 2, burst saw 7 → 7.
        XCTAssertEqual(
            VoiceReceiveDecisions.jitterBufferTarget(
                smoothedJitterMs: 0, burstDepth: 7, currentTarget: 2),
            7)
    }

    func testTargetClampsAtMaxDepth() {
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 10_000, currentTarget: 12), 12)
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 10_000, currentTarget: 11), 12)
    }

    func testTargetHoldsWhenIdealMatches() {
        // ~30 ms of jitter → ceil(30 / 21.33) = 2 slack + 1 base = 3.
        XCTAssertEqual(VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: 30, currentTarget: 3), 3)
    }

    func testTargetMonotoneInBurstDepth() {
        var previous = 0
        for burst in 0...20 {
            let target = VoiceReceiveDecisions.jitterBufferTarget(
                smoothedJitterMs: 0, burstDepth: burst, currentTarget: 2)
            XCTAssertGreaterThanOrEqual(target, previous, "target must not shrink as bursts grow")
            previous = target
        }
    }

    func testTargetMonotoneInJitter() {
        var previous = 0
        for jitterMs in stride(from: 0.0, through: 300.0, by: 10.0) {
            let target = VoiceReceiveDecisions.jitterBufferTarget(smoothedJitterMs: jitterMs, currentTarget: 7)
            XCTAssertGreaterThanOrEqual(target, previous, "target must not shrink as jitter grows")
            previous = target
        }
    }

    // MARK: - PlayoutBacklog

    private static let frameNs = VoiceReceiveDecisions.frameDurationNs

    /// A stream arriving exactly on time never needs more than one buffer.
    /// If this drifts upward the tracker would inflate every target on every
    /// healthy call, which is the one way this change could make things worse.
    func testSteadyArrivalsNeverBacklog() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        for i in 0..<500 {
            backlog.noteFrameQueued(nowNs: UInt64(i) * Self.frameNs)
        }
        XCTAssertEqual(backlog.peakDepth, 1)
    }

    /// A sender whose clock runs fast genuinely does back the queue up, and
    /// the model says so — but it stays bounded rather than running away.
    ///
    /// Worth being exact about, because this is the one case where sizing on
    /// backlog behaves differently from sizing on jitter, and not entirely
    /// for the better. Drift is not a burst: the right answer to it is the
    /// cap (bound the latency, drop the excess), which is what the cap was
    /// always for. Sizing on backlog lets the buffer follow the drift up to
    /// `maxDepth` first, so a persistently fast sender reaches a deeper
    /// buffer — and more mouth-to-ear latency — before dropping starts than
    /// it used to. It is bounded either way, and the rates that matter are
    /// slow: at a realistic 0.1 % the climb to `maxDepth` takes minutes.
    /// This pins the bound, not an absence of accumulation.
    func testClockDriftBacklogsButStaysBounded() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        let fast = Self.frameNs - 100_000  // 19.9 ms — a 0.5 % fast sender
        for i in 0..<2000 {
            backlog.noteFrameQueued(nowNs: UInt64(i) * fast)
        }
        XCTAssertGreaterThan(backlog.peakDepth, 1, "drift does back the queue up")
        XCTAssertLessThanOrEqual(
            backlog.peakDepth, VoiceReceiveDecisions.PlayoutBacklog.depthCeiling,
            "but the model is bounded, so nothing runs away")
    }

    /// The shape the whole change exists for: the path stalls, then delivers
    /// everything it was holding at once.
    func testAStallThenABurstReportsTheBurstDepth() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        backlog.noteFrameQueued(nowNs: 0)
        // 300 ms of nothing, then 15 frames inside 2 ms.
        let burstStart: UInt64 = 300_000_000
        for i in 0..<15 {
            backlog.noteFrameQueued(nowNs: burstStart + UInt64(i) * 100_000)
        }
        XCTAssertEqual(backlog.peakDepth, 15)
    }

    /// Playout keeps consuming during a slower burst, so the depth demanded
    /// is the arrivals minus what played — not the raw arrival count.
    func testASpreadBurstDemandsLessThanItsFrameCount() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        backlog.noteFrameQueued(nowNs: 0)
        let burstStart: UInt64 = 300_000_000
        // 15 frames over 100 ms — playout drains ~5 of them on the way.
        for i in 0..<15 {
            backlog.noteFrameQueued(nowNs: burstStart + UInt64(i) * (Self.frameNs / 3))
        }
        XCTAssertGreaterThan(backlog.peakDepth, 5)
        XCTAssertLessThan(backlog.peakDepth, 15)
    }

    /// Draining hands over the peak and opens the next window at the depth
    /// still outstanding — a burst mid-drain is a demand the next window
    /// inherits, and resetting to zero would under-report it exactly when it
    /// matters most.
    func testDrainCarriesTheOutstandingDepthIntoTheNextWindow() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        backlog.noteFrameQueued(nowNs: 0)
        let burstStart: UInt64 = 300_000_000
        for i in 0..<10 {
            backlog.noteFrameQueued(nowNs: burstStart + UInt64(i) * 100_000)
        }
        XCTAssertEqual(backlog.drainPeak(), 10)
        XCTAssertEqual(backlog.peakDepth, 10, "still 10 frames deep, so the next window starts there")
    }

    /// A clock that steps backwards must not hang the drain loop or invent
    /// a backlog — the monotonic clock should not do this, but the tracker
    /// cannot know its caller used one.
    func testBackwardClockIsSurvivable() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        backlog.noteFrameQueued(nowNs: 1_000_000_000)
        backlog.noteFrameQueued(nowNs: 0)
        backlog.noteFrameQueued(nowNs: 500_000)
        XCTAssertLessThanOrEqual(backlog.peakDepth, VoiceReceiveDecisions.PlayoutBacklog.depthCeiling)
    }

    /// The model is capped, so a pathological gap cannot make the drain loop
    /// long or the reported demand absurd.
    func testDepthIsCeilinged() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        for i in 0..<500 {
            backlog.noteFrameQueued(nowNs: UInt64(i))  // all inside one frame
        }
        XCTAssertEqual(backlog.peakDepth, VoiceReceiveDecisions.PlayoutBacklog.depthCeiling)
    }

    func testResetForgetsEverything() {
        var backlog = VoiceReceiveDecisions.PlayoutBacklog()
        for i in 0..<10 { backlog.noteFrameQueued(nowNs: UInt64(i)) }
        XCTAssertGreaterThan(backlog.peakDepth, 1)
        backlog.reset()
        XCTAssertEqual(backlog.peakDepth, 0)
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
