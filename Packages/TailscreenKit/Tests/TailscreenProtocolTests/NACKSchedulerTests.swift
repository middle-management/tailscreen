import XCTest

@testable import TailscreenProtocol

/// Pure-decision tests for the viewer's `NACKScheduler`: reorder tolerance
/// (pure reordering must never NACK), the retry cadence keyed to injected RTT,
/// PLI fallback on ring-age / attempt exhaustion, and the FCI packing. No I/O,
/// no wall clock — every decision is reproducible on injected `nowNs`, so this
/// runs on CI unlike the live net-impair harness.
final class NACKSchedulerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let s: UInt64 = 1_000_000_000

    func testFirstPacketOpensNoGap() {
        var sched = NACKScheduler()
        XCTAssertTrue(sched.observe(seq: 100, nowNs: 0).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
    }

    /// 100, 102, 101 within tolerance: the reordered gap fills before eligible.
    func testPureReorderProducesNoNACKs() {
        var sched = NACKScheduler()
        XCTAssertTrue(sched.observe(seq: 100, nowNs: 0).isEmpty)
        XCTAssertTrue(sched.observe(seq: 102, nowNs: 1 * ms).isEmpty)
        XCTAssertTrue(sched.observe(seq: 101, nowNs: 2 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testGenuineLossNACKsAfterToleranceThenPLIs() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)  // reNack = 90 ms
        XCTAssertTrue(sched.observe(seq: 0, nowNs: 0).isEmpty)
        XCTAssertTrue(sched.observe(seq: 5, nowNs: 0).isEmpty)  // gaps 1..4
        let first = sched.tick(nowNs: 20 * ms)
        XCTAssertEqual(first, [.sendNACK([1, 2, 3, 4])])
        XCTAssertTrue(sched.tick(nowNs: 40 * ms).isEmpty)  // not due yet
        XCTAssertEqual(sched.tick(nowNs: 120 * ms), [.sendNACK([1, 2, 3, 4])])
        XCTAssertEqual(sched.tick(nowNs: 220 * ms), [.sendNACK([1, 2, 3, 4])])
        // Fourth pass: attempts exhausted (max 3) → abandon to PLI.
        XCTAssertEqual(sched.tick(nowNs: 320 * ms), [.sendPLI])
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testGapAgedPastRingWindowFallsBackToPLI() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 3, nowNs: 0)  // gaps 1,2
        XCTAssertEqual(sched.tick(nowNs: 1_100 * ms), [.sendPLI])  // older than 1s ring window
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testRetransmitFillsGapNoPLI() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 3, nowNs: 0)  // gaps 1,2 open
        XCTAssertTrue(sched.observe(seq: 1, nowNs: 5 * ms).isEmpty)
        XCTAssertTrue(sched.observe(seq: 2, nowNs: 6 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertTrue(sched.tick(nowNs: 500 * ms).isEmpty)
    }

    /// A NACKed-then-filled gap is genuine link loss the retransmit repaired
    /// — the count the FEC arm needs to reconstruct raw loss.
    func testServedRetransmitCountsAsRecovery() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1 opens
        XCTAssertEqual(sched.tick(nowNs: 20 * ms), [.sendNACK([1])])  // NACK sent → attempts=1
        _ = sched.observe(seq: 1, nowNs: 200 * ms)  // retransmit fills it
        XCTAssertEqual(sched.drainNackRecovered(), 1)
        XCTAssertEqual(sched.drainNackRecovered(), 0, "read-and-reset")
    }

    /// A gap filled before any NACK fired was never a link loss.
    func testReorderFillIsNotARecovery() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)
        _ = sched.observe(seq: 1, nowNs: 5 * ms)  // fills before eligible; no NACK
        XCTAssertEqual(sched.drainNackRecovered(), 0)
    }

    /// Three newer packets (>= reorderPacketTolerance) make the gap eligible
    /// before the 15ms time tolerance elapses.
    func testPacketCountToleranceMakesGapEligibleEarly() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1, newerSeen 1
        _ = sched.observe(seq: 3, nowNs: 1 * ms)  // newerSeen 2
        let actions = sched.observe(seq: 4, nowNs: 2 * ms)  // newerSeen 3 → eligible
        XCTAssertEqual(actions, [.sendNACK([1])])
    }

    func testRTTWidensReNackInterval() {
        var slow = NACKScheduler(initialRTTNs: 400_000_000)  // reNack = 600 ms
        _ = slow.observe(seq: 0, nowNs: 0)
        _ = slow.observe(seq: 2, nowNs: 0)
        XCTAssertEqual(slow.tick(nowNs: 20 * ms), [.sendNACK([1])])
        // A 60ms-RTT scheduler would already re-NACK at 300ms; this holds until 620ms.
        XCTAssertTrue(slow.tick(nowNs: 300 * ms).isEmpty)
        XCTAssertEqual(slow.tick(nowNs: 640 * ms), [.sendNACK([1])])
    }

    /// 20 isolated missing seqs → 20 FCI groups; capped to 16.
    func testFCICappedSeqsBoundsToSixteenGroups() {
        let seqs = (0..<20).map { UInt16($0 * 20) }
        let capped = NACKScheduler.fciCappedSeqs(seqs)
        XCTAssertEqual(capped.count, 16)
        XCTAssertEqual(capped, Array(seqs.prefix(16)))
    }

    /// A dense contiguous run packs 17 seqs/group, so 30 fit in 2 groups.
    func testFCICappedSeqsKeepsContiguousRun() {
        let seqs = (0..<30).map { UInt16($0) }
        XCTAssertEqual(NACKScheduler.fciCappedSeqs(seqs).sorted(), seqs)
    }

    /// A 50-packet contiguous loss must be NACKed in full, not truncated.
    func testContiguousGapRunFullyNACKed() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 51, nowNs: 0)  // gaps 1…50
        let actions = sched.tick(nowNs: 20 * ms)
        guard let first = actions.first, case .sendNACK(let seqs) = first else {
            XCTFail("expected a NACK")
            return
        }
        XCTAssertEqual(seqs.sorted(), (1...50).map { UInt16($0) })
        XCTAssertFalse(actions.contains(.sendPLI), "a repairable run must not PLI")
    }

    /// A jump beyond maxGaps (256) is a discontinuity: just a keyframe
    /// request, not gap tracking.
    func testLargeSeqJumpFallsBackToPLI() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        let actions = sched.observe(seq: 300, nowNs: 1 * ms)
        XCTAssertEqual(actions, [.sendPLI])
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testRTTAdaptsFromRetransmitRoundTrip() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)
        XCTAssertEqual(sched.rttEstimateNs, 60_000_000)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1
        XCTAssertEqual(sched.tick(nowNs: 20 * ms), [.sendNACK([1])])
        _ = sched.observe(seq: 1, nowNs: 120 * ms)  // retransmit → RTT sample 100ms
        XCTAssertEqual(sched.rttEstimateNs, 65_000_000)  // EMA: (60·7 + 100) / 8
    }

    /// FEC recovery after a NACK went out must clear with NO RTT sample —
    /// the straggler path would inject FEC latency into the RTT EMA.
    func testCancelGapClearsWithoutRTTSampleOrPLI() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1
        XCTAssertEqual(sched.tick(nowNs: 20 * ms), [.sendNACK([1])])
        sched.cancelGap(seq: 1)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertEqual(sched.rttEstimateNs, 60_000_000, "cancelGap must not feed the RTT estimate")
        XCTAssertTrue(sched.tick(nowNs: 2 * s).isEmpty, "no re-NACK and no PLI after cancel")
    }

    func testCancelGapBeforeAnyNACKSuppressesIt() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 1 * ms)
        sched.cancelGap(seq: 1)
        XCTAssertTrue(sched.tick(nowNs: 500 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testCancelGapUntrackedSeqIsANoOp() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        sched.cancelGap(seq: 42)
        XCTAssertFalse(sched.hasOpenGaps)
    }

    /// The marker (batch-final) packet is lost and FEC-recovered, ahead of
    /// every wire packet — a bare gap-cancel would leave `highestSeq` behind
    /// it, re-opening a phantom gap on the next batch. `noteRecovered` must
    /// advance the cursor.
    func testNoteRecoveredAdvancesPastTailOfBatchLoss() {
        var sched = NACKScheduler()
        for seq in 0...8 {
            _ = sched.observe(seq: UInt16(seq), nowNs: UInt64(seq) * ms)
        }
        sched.noteRecovered(seq: 9, nowNs: 10 * ms)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertTrue(sched.observe(seq: 10, nowNs: 11 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertTrue(sched.tick(nowNs: 2 * s).isEmpty)
    }

    /// Mid-batch recovery: same no-RTT-sample rule as `cancelGap`.
    func testNoteRecoveredClearsGapWithoutRTTSample() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1
        XCTAssertEqual(sched.tick(nowNs: 20 * ms), [.sendNACK([1])])
        sched.noteRecovered(seq: 1, nowNs: 30 * ms)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertEqual(sched.rttEstimateNs, 60_000_000, "recovery latency must not feed the RTT EMA")
        XCTAssertTrue(sched.tick(nowNs: 2 * s).isEmpty)
    }

    /// A recovery two ahead of the highest wire packet means the seq in
    /// between never arrived and must still be tracked as a real gap.
    func testNoteRecoveredOpensGapsForGenuinelySkippedSeqs() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        sched.noteRecovered(seq: 2, nowNs: 1 * ms)
        XCTAssertTrue(sched.hasOpenGaps, "seq 1 is genuinely missing")
        XCTAssertEqual(sched.tick(nowNs: 30 * ms), [.sendNACK([1])])
    }

    /// FEC arming/disarming retunes eligibility WITHOUT dropping tracked
    /// gaps or the adapted RTT estimate (a scheduler rebuild would).
    func testSetReorderTolerancesSwitchesInPlace() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1, newerSeen 1
        sched.setReorderTolerances(
            toleranceNs: TransportTuning.fecSchedulerToleranceNs,
            packetTolerance: TransportTuning.fecSchedulerPacketTolerance)
        XCTAssertTrue(sched.tick(nowNs: 20 * ms).isEmpty, "20 ms < the relaxed 25 ms tolerance")
        sched.setReorderTolerances(
            toleranceNs: NACKScheduler.defaultReorderToleranceNs,
            packetTolerance: NACKScheduler.defaultReorderPacketTolerance)
        XCTAssertEqual(sched.tick(nowNs: 21 * ms), [.sendNACK([1])])
        XCTAssertEqual(sched.rttEstimateNs, 60_000_000)
    }

    /// A gap must NOT become NACK-eligible while a recovery could still be
    /// in flight (up to N-1 trailing group members plus parity), and must
    /// fire once the newer-packet count exceeds tolerance.
    func testFECModeTolerancesDelayNACKUntilBeyondGroupSpan() {
        var sched = NACKScheduler(
            reorderToleranceNs: TransportTuning.fecSchedulerToleranceNs,
            reorderPacketTolerance: TransportTuning.fecSchedulerPacketTolerance)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1, newerSeen 1
        var actions: [NACKAction] = []
        for i in 0..<11 {
            XCTAssertTrue(actions.isEmpty, "NACK fired early at newerSeen \(i + 1)")
            actions = sched.observe(seq: UInt16(3 + i), nowNs: UInt64(i) * ms)
        }
        XCTAssertEqual(actions, [.sendNACK([1])], "gap must go out once past the FEC-mode tolerance")
    }

    func testFECModeTimeToleranceIs25ms() {
        var sched = NACKScheduler(
            reorderToleranceNs: TransportTuning.fecSchedulerToleranceNs,
            reorderPacketTolerance: TransportTuning.fecSchedulerPacketTolerance)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)
        XCTAssertTrue(sched.tick(nowNs: 24 * ms).isEmpty, "under the 25 ms FEC slack")
        XCTAssertEqual(sched.tick(nowNs: 25 * ms), [.sendNACK([1])])
    }

    func testFCIPacking() {
        let single = NACKScheduler.packFCI([1, 2, 3, 4])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].pid, 1)
        XCTAssertEqual(single[0].blp, 0b0000_0000_0000_0111)  // 2,3,4

        // A gap wider than 16 forces a second FCI entry.
        let split = NACKScheduler.packFCI([1, 20])
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].pid, 1)
        XCTAssertEqual(split[0].blp, 0)
        XCTAssertEqual(split[1].pid, 20)
        XCTAssertEqual(split[1].blp, 0)
    }

    // MARK: - Sequence wraparound (65535 → 0)

    /// Observing 65534 then 2 must open gaps {65535, 0, 1}, all NACKed together.
    func testGapAcrossWrapIsTrackedAndNACKed() {
        var sched = NACKScheduler()
        XCTAssertTrue(sched.observe(seq: 65534, nowNs: 0).isEmpty)
        XCTAssertTrue(sched.observe(seq: 2, nowNs: 0).isEmpty)
        XCTAssertTrue(sched.hasOpenGaps)
        // fciCappedSeqs sorts numerically: datagram covers [0, 1, 65535].
        XCTAssertEqual(sched.tick(nowNs: 20 * ms), [.sendNACK([0, 1, 65535])])
    }

    func testStragglerAcrossWrapFillsGapAndFeedsRTT() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)
        _ = sched.observe(seq: 65534, nowNs: 0)
        _ = sched.observe(seq: 1, nowNs: 0)  // gaps {65535, 0}
        XCTAssertEqual(sched.tick(nowNs: 20 * ms), [.sendNACK([0, 65535])])
        XCTAssertTrue(sched.observe(seq: 65535, nowNs: 60 * ms).isEmpty)
        XCTAssertTrue(sched.observe(seq: 0, nowNs: 60 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertEqual(sched.rttEstimateNs, 55_312_500)  // EMA over two 40ms samples
        XCTAssertTrue(sched.tick(nowNs: 2 * s).isEmpty)
    }

    /// A >maxGaps discontinuity computed ACROSS the wrap must still be
    /// classified as a discontinuity (wrap-safe `&-` distance).
    func testLargeSeqJumpAcrossWrapFallsBackToPLI() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 65530, nowNs: 0)
        let actions = sched.observe(seq: 65530 &+ 300, nowNs: 1 * ms)
        XCTAssertEqual(actions, [.sendPLI])
        XCTAssertFalse(sched.hasOpenGaps)
    }

    /// PINS CURRENT BEHAVIOR: `packFCI`'s plain numeric sort is not
    /// wrap-aware, so a wrap-spanning gap set splits into two FCI groups
    /// instead of one. An efficiency wart, not a correctness bug — every
    /// seq is still covered. If you make the sort wrap-aware, update this
    /// test and keep the coverage invariant.
    func testPackFCIWrapPinsCurrentTwoGroupBehavior() {
        let entries = NACKScheduler.packFCI([65534, 65535, 0, 1])
        XCTAssertEqual(entries.count, 2, "wrap-spanning set currently splits at the boundary")
        XCTAssertEqual(entries[0].pid, 0)
        XCTAssertEqual(entries[0].blp, 0b1)  // covers 1
        XCTAssertEqual(entries[1].pid, 65534)
        XCTAssertEqual(entries[1].blp, 0b1)  // covers 65535
        var covered: Set<UInt16> = []
        for entry in entries {
            covered.insert(entry.pid)
            for bit in 0..<16 where entry.blp & (1 << bit) != 0 {
                covered.insert(entry.pid &+ UInt16(bit) &+ 1)
            }
        }
        XCTAssertEqual(covered, [65534, 65535, 0, 1])
    }

    func testFCICappedSeqsWrapCoversEverySeq() {
        let onWire = NACKScheduler.fciCappedSeqs([65534, 65535, 0, 1])
        XCTAssertEqual(Set(onWire), [65534, 65535, 0, 1])
    }
}
