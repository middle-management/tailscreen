import XCTest

@testable import Tailscreen

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

    func testPureReorderProducesNoNACKs() {
        // 100, 102, 101 within the reorder tolerance: the single reordered gap
        // fills before it's eligible (one newer packet < 3-packet tolerance,
        // ~0 ms < 15 ms time tolerance). Zero NACKs, zero PLIs.
        var sched = NACKScheduler()
        XCTAssertTrue(sched.observe(seq: 100, nowNs: 0).isEmpty)
        XCTAssertTrue(sched.observe(seq: 102, nowNs: 1 * ms).isEmpty)
        XCTAssertTrue(sched.observe(seq: 101, nowNs: 2 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testGenuineLossNACKsAfterToleranceThenPLIs() {
        var sched = NACKScheduler(initialRTTNs: 60_000_000)  // reNack = 90 ms
        XCTAssertTrue(sched.observe(seq: 0, nowNs: 0).isEmpty)
        // Jump to seq 5 — gaps 1..4 open, all within tolerance so far.
        XCTAssertTrue(sched.observe(seq: 5, nowNs: 0).isEmpty)
        // Past the 15 ms reorder tolerance: one batched NACK for all four.
        let first = sched.tick(nowNs: 20 * ms)
        XCTAssertEqual(first, [.sendNACK([1, 2, 3, 4])])
        // Not due to re-NACK yet (< 90 ms since last).
        XCTAssertTrue(sched.tick(nowNs: 40 * ms).isEmpty)
        // Second and third attempts on the RTT cadence.
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
        // Older than the 1 s ring window → PLI without any (useless) NACK.
        XCTAssertEqual(sched.tick(nowNs: 1_100 * ms), [.sendPLI])
        XCTAssertFalse(sched.hasOpenGaps)
    }

    func testRetransmitFillsGapNoPLI() {
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 3, nowNs: 0)  // gaps 1,2 open
        // Retransmits (or reordered originals) arrive "behind" the highest seq
        // and clear the gaps — no PLI ever fires.
        XCTAssertTrue(sched.observe(seq: 1, nowNs: 5 * ms).isEmpty)
        XCTAssertTrue(sched.observe(seq: 2, nowNs: 6 * ms).isEmpty)
        XCTAssertFalse(sched.hasOpenGaps)
        XCTAssertTrue(sched.tick(nowNs: 500 * ms).isEmpty)
    }

    func testPacketCountToleranceMakesGapEligibleEarly() {
        // Three newer packets (>= reorderPacketTolerance) make the gap eligible
        // even before the 15 ms time tolerance elapses.
        var sched = NACKScheduler()
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1, newerSeen 1
        _ = sched.observe(seq: 3, nowNs: 1 * ms)  // newerSeen 2
        let actions = sched.observe(seq: 4, nowNs: 2 * ms)  // newerSeen 3 → eligible
        XCTAssertEqual(actions, [.sendNACK([1])])
    }

    func testRTTWidensReNackInterval() {
        // A large RTT stretches the re-NACK interval past a small-RTT one.
        var slow = NACKScheduler(initialRTTNs: 400_000_000)  // reNack = 600 ms
        _ = slow.observe(seq: 0, nowNs: 0)
        _ = slow.observe(seq: 2, nowNs: 0)
        XCTAssertEqual(slow.tick(nowNs: 20 * ms), [.sendNACK([1])])
        // At 300 ms a 60 ms-RTT scheduler would already re-NACK; the 400 ms-RTT
        // one holds until 620 ms.
        XCTAssertTrue(slow.tick(nowNs: 300 * ms).isEmpty)
        XCTAssertEqual(slow.tick(nowNs: 640 * ms), [.sendNACK([1])])
    }

    func testFCICappedSeqsBoundsToSixteenGroups() {
        // 20 isolated (20-apart) missing seqs → 20 FCI groups; capped to 16.
        let seqs = (0..<20).map { UInt16($0 * 20) }
        let capped = NACKScheduler.fciCappedSeqs(seqs)
        XCTAssertEqual(capped.count, 16)
        XCTAssertEqual(capped, Array(seqs.prefix(16)))
    }

    func testFCICappedSeqsKeepsContiguousRun() {
        // A dense contiguous run packs 17 seqs/group, so 30 seqs fit in 2
        // groups — well under the cap; none dropped.
        let seqs = (0..<30).map { UInt16($0) }
        XCTAssertEqual(NACKScheduler.fciCappedSeqs(seqs).sorted(), seqs)
    }

    func testContiguousGapRunFullyNACKed() {
        // A 50-packet contiguous loss (< 16 FCI groups) must be NACKed in full,
        // not truncated by the FCI cap.
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

    func testLargeSeqJumpFallsBackToPLI() {
        // A jump beyond maxGaps (256) is a discontinuity: neither NACK nor gap
        // tracking, just a keyframe request (else the viewer freezes with the
        // depacketizer PLI suppressed in NACK mode).
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
        // Retransmit of seq 1 lands 100 ms after the NACK → RTT sample 100 ms.
        _ = sched.observe(seq: 1, nowNs: 120 * ms)
        // EMA: (60·7 + 100) / 8 = 65 ms.
        XCTAssertEqual(sched.rttEstimateNs, 65_000_000)
    }

    func testCancelGapClearsWithoutRTTSampleOrPLI() {
        // FEC recovered the packet after a NACK already went out: the gap
        // must clear with NO RTT sample (the straggler path would inject FEC
        // latency into the RTT EMA) and no PLI.
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
        // FEC recovery lands inside the reorder tolerance: the gap is
        // cancelled before it ever becomes NACK-eligible.
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

    func testFECModeTolerancesDelayNACKUntilBeyondGroupSpan() {
        // FEC-mode construction (N+2 packets / 25 ms): a gap must NOT become
        // NACK-eligible while a recovery could still be in flight — up to
        // N−1 trailing group members plus the parity — and must fire once
        // the newer-packet count exceeds the tolerance.
        var sched = NACKScheduler(
            reorderToleranceNs: TransportTuning.fecSchedulerToleranceNs,
            reorderPacketTolerance: TransportTuning.fecSchedulerPacketTolerance)
        _ = sched.observe(seq: 0, nowNs: 0)
        _ = sched.observe(seq: 2, nowNs: 0)  // gap 1, newerSeen 1
        // 11 more newer packets → newerSeen 12 = tolerance → eligible; the
        // one before (newerSeen 11) must produce nothing.
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
        // Contiguous run collapses into one entry with a bitmask.
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
}
