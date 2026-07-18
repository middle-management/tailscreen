import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Pure-decision tests for the adaptive-FEC arm of the congestion sweep
/// (`fecSweepDecision` + its helpers): the strictly PER-VIEWER RTT ∧ loss
/// gate (mixing worst-RTT and worst-loss across different viewers must never
/// switch FEC on with nobody gated), the raw-loss group-size ladder, raw-loss
/// reconstruction from residual + recovered against each viewer's OWN
/// expected packet count (multi-viewer recovery sums must not inflate; a
/// keyframe-only throttled viewer's small denominator must keep its gate
/// stable), the two-clean-windows off-hysteresis, and the N/(N+1) encoder
/// compensation with its floor clamp.
final class FECOverheadDecisionTests: XCTestCase {
    private typealias Server = TailscaleScreenShareServer
    private typealias State = TailscaleScreenShareServer.FECState
    private typealias Sample = TailscaleScreenShareServer.FECViewerSample
    private typealias Decision = TailscaleScreenShareServer.FECSweepDecision
    private let ms: UInt64 = 1_000_000

    private func sample(
        rttMs: UInt64, residualQ8: Int = 0, recovered: Int = 0, nackRecovered: Int = 0,
        expected: Int = 1000, capable: Bool = true
    ) -> Sample {
        Sample(
            rttNs: rttMs * ms, residualLossQ8: residualQ8, recovered: recovered,
            nackRecovered: nackRecovered, expectedPackets: expected, fecCapable: capable)
    }

    private func decide(_ samples: [String: Sample], state: State = State()) -> Decision {
        Server.fecSweepDecision(samples: samples, state: state)
    }

    // MARK: - Per-viewer on-gate

    func testSlowLossyViewerGatesOn() {
        let d = decide(["v": sample(rttMs: 200, residualQ8: 8)])
        XCTAssertEqual(d.state, State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.gated, ["v"])
    }

    func testNackMaskedLossStillGatesOn() {
        // NACK is repairing the loss so RR residual is low (2 < gate), but at
        // high RTT — exactly where FEC's zero-RTT recovery beats NACK's per-loss
        // round trip. The NACK-recovered count must feed raw-loss reconstruction
        // so the gate still trips: residual 2 + (40/1000 → Q8 10) = 12 raw.
        let d = decide(["v": sample(rttMs: 200, residualQ8: 2, nackRecovered: 40)])
        XCTAssertEqual(d.gated, ["v"])
        XCTAssertEqual(d.state.groupSize, 7)  // 12 raw > fecMidLossQ8 (10) → medium
    }

    func testNackRecoveryAloneOnFastPathStaysOff() {
        // Same raw loss but RTT 100 ms < 150 ms: NACK round trip is cheap, so
        // no parity — the gate needs BOTH high RTT and high raw loss.
        let d = decide(["v": sample(rttMs: 100, residualQ8: 2, nackRecovered: 40)])
        XCTAssertTrue(d.gated.isEmpty)
    }

    func testLossyButFastPathStaysOff() {
        // ~3 % loss but RTT 100 ms < 150 ms: NACK beats render — no parity.
        let d = decide(["v": sample(rttMs: 100, residualQ8: 8)])
        XCTAssertEqual(d.state, State())
        XCTAssertTrue(d.gated.isEmpty)
    }

    func testSlowButCleanPathStaysOff() {
        let d = decide(["v": sample(rttMs: 300, residualQ8: 2)])
        XCTAssertEqual(d.state, State())
        XCTAssertTrue(d.gated.isEmpty)
    }

    func testGateBoundariesAreExclusive() {
        // Exactly 150 ms / exactly 2 % (Q8 5) do NOT gate on.
        XCTAssertEqual(decide(["v": sample(rttMs: 150, residualQ8: 8)]).state, State())
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 5)]).state, State())
        XCTAssertFalse(Server.fecViewerGate(rttNs: 150 * ms, rawLossQ8: 8))
        XCTAssertFalse(Server.fecViewerGate(rttNs: 200 * ms, rawLossQ8: 5))
        XCTAssertTrue(Server.fecViewerGate(rttNs: 151 * ms, rawLossQ8: 6))
    }

    func testCrossViewerMixingNeverTurnsFECOn() {
        // Viewer A: slow but clean. Viewer B: lossy but fast. Taking
        // worst-RTT and worst-loss over DIFFERENT viewers would say ON with
        // an empty gated set — the encoder paying N/(N+1) for parity nobody
        // receives. The per-viewer gate must keep FEC off entirely.
        let samples = [
            "slowClean": sample(rttMs: 200, residualQ8: 0),
            "fastLossy": sample(rttMs: 50, residualQ8: 13)
        ]
        let d = decide(samples)
        XCTAssertEqual(d.state, State(), "no single viewer qualifies — FEC must stay off")
        XCTAssertTrue(d.gated.isEmpty)
    }

    func testCrossViewerMixingFromOnStateHoldsWithoutGatedViewers() {
        // Same A+B while already ON (e.g. B's RTT just dropped): loss is
        // still present (not clean) so N is held for a quick re-arm, but the
        // gated set is EMPTY — the applier sends no parity and must pay no
        // compensation (compensation follows the gated set, not the held N).
        let samples = [
            "slowClean": sample(rttMs: 200, residualQ8: 0),
            "fastLossy": sample(rttMs: 50, residualQ8: 13)
        ]
        let d = decide(samples, state: State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.state, State(groupSize: 10, cleanWindows: 0))
        XCTAssertTrue(d.gated.isEmpty, "held N with nobody gated ⇒ no parity, no compensation")
    }

    // MARK: - Loss ladder (raw loss → group size)

    func testLadderBands() {
        // 2–4 % → 10; 4–8 % → 7; > 8 % → 5. Band edges: Q8 10 (~3.9 %) is
        // still the light band, 11 crosses to medium; 20 medium, 21 heavy.
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 6)]).state.groupSize, 10)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 10)]).state.groupSize, 10)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 11)]).state.groupSize, 7)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 20)]).state.groupSize, 7)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 21)]).state.groupSize, 5)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 255)]).state.groupSize, 5)
    }

    func testLadderReadjustsWhileOn() {
        // Loss worsens: on at N=10, raw ~6 % → step to 7.
        let on = State(groupSize: 10, cleanWindows: 0)
        let d = decide(["v": sample(rttMs: 200, residualQ8: 15)], state: on)
        XCTAssertEqual(d.state.groupSize, 7)
        XCTAssertEqual(d.gated, ["v"])
    }

    func testLadderFollowsWorstGatedViewer() {
        // Two gated viewers: the worse one sizes the group.
        let samples = [
            "mild": sample(rttMs: 200, residualQ8: 7),
            "bad": sample(rttMs: 300, residualQ8: 25)
        ]
        let d = decide(samples)
        XCTAssertEqual(d.state.groupSize, 5)
        XCTAssertEqual(d.gated, ["mild", "bad"])
    }

    // MARK: - Anti-oscillation (the fecRecovered term)

    func testFECHidingAllLossStaysOn() {
        // Residual ≈ 0 because parity is repairing everything; the recovered
        // term reconstructs raw loss, so FEC must NOT gate off (which would
        // re-trigger the loss it's hiding).
        let on = State(groupSize: 10, cleanWindows: 0)
        let d = decide(
            ["v": sample(rttMs: 200, residualQ8: 0, recovered: 30, expected: 1000)], state: on)
        XCTAssertEqual(d.state, State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.gated, ["v"], "a viewer whose parity is doing work keeps its parity")
    }

    func testRecoveredTermCountsTowardOnGate() {
        // Residual 1 % + recovered ~1.5 % crosses the 2 % raw gate.
        let d = decide(["v": sample(rttMs: 200, residualQ8: 3, recovered: 15, expected: 1000)])
        XCTAssertEqual(d.state.groupSize, 10)
        XCTAssertEqual(d.gated, ["v"])
    }

    // MARK: - Per-viewer denominators (recovered → raw loss)

    func testMultiViewerRecoveriesDoNotInflate() {
        // Two viewers each recovering ~3 % of their OWN 1000-packet stream:
        // per-viewer raw loss is ~3 % each — NOT 6 % against one stream — so
        // the ladder stays at 10, not 7.
        let samples = [
            "a": sample(rttMs: 200, residualQ8: 0, recovered: 30, expected: 1000),
            "b": sample(rttMs: 250, residualQ8: 0, recovered: 30, expected: 1000)
        ]
        let d = decide(samples, state: State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.state.groupSize, 10, "summing recoveries across viewers over-ladders overhead")
        XCTAssertEqual(d.gated, ["a", "b"])
    }

    func testThrottledViewerGateStableAgainstOwnDenominator() {
        // A keyframe-only throttled viewer's window carries few packets (40,
        // not the ~1000 templates). Recovering 2 of them is 5 % raw loss —
        // its gate must HOLD. Divided by the template-stream count it would
        // read ~0.05 % and drop the gate, setting up the gate-drop → loss →
        // PLI-storm → re-gate oscillation.
        let d = decide(
            ["throttled": sample(rttMs: 300, residualQ8: 0, recovered: 2, expected: 40)],
            state: State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.gated, ["throttled"], "per-viewer denominator must keep the gate latched")
        XCTAssertGreaterThan(d.state.groupSize, 0)
    }

    func testRecoveredQ8Conversion() {
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 0, expectedPackets: 1000), 0)
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 10, expectedPackets: 1000), 2)  // 1 % ≈ Q8 2
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 500, expectedPackets: 1000), 128)
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 5000, expectedPackets: 1000), 255, "clamped")
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 10, expectedPackets: 0), 0, "no expected → no signal")
    }

    // MARK: - Off-gate hysteresis

    func testTwoConsecutiveCleanWindowsGateOff() {
        let on = State(groupSize: 7, cleanWindows: 0)
        let afterOne = decide(["v": sample(rttMs: 200, residualQ8: 0)], state: on)
        XCTAssertEqual(
            afterOne.state, State(groupSize: 7, cleanWindows: 1), "first clean window holds parity")
        XCTAssertTrue(afterOne.gated.isEmpty, "clean viewer receives no parity while winding down")
        let afterTwo = decide(["v": sample(rttMs: 200, residualQ8: 0)], state: afterOne.state)
        XCTAssertEqual(afterTwo.state, State(), "second clean window gates off")
        XCTAssertTrue(afterTwo.gated.isEmpty)
    }

    func testLossResetsCleanWindowCount() {
        let oneClean = State(groupSize: 10, cleanWindows: 1)
        let d = decide(["v": sample(rttMs: 200, residualQ8: 8)], state: oneClean)
        XCTAssertEqual(d.state, State(groupSize: 10, cleanWindows: 0))
    }

    func testGrayZoneHoldsCurrentGroupWithEmptyGate() {
        // Raw loss between clean (< 1 %) and the gate (≤ 2 %): not clean,
        // nobody gated — hold N (quick re-arm) with an empty gated set.
        let on = State(groupSize: 7, cleanWindows: 1)
        let d = decide(["v": sample(rttMs: 200, residualQ8: 4)], state: on)
        XCTAssertEqual(d.state, State(groupSize: 7, cleanWindows: 0))
        XCTAssertTrue(d.gated.isEmpty)
    }

    // MARK: - Legacy exclusion

    func testLegacyViewersNeverGateOrDriveTheDecision() {
        // A non-`.fec` viewer, however lossy/slow, is invisible to the FEC
        // arm — it can neither switch parity on nor hold it on.
        let d = decide(["legacy": sample(rttMs: 500, residualQ8: 80, capable: false)])
        XCTAssertEqual(d.state, State())
        XCTAssertTrue(d.gated.isEmpty)
        let fromOn = decide(
            ["legacy": sample(rttMs: 500, residualQ8: 80, capable: false)],
            state: State(groupSize: 10, cleanWindows: 0))
        XCTAssertTrue(fromOn.gated.isEmpty)
        XCTAssertEqual(
            fromOn.state, State(groupSize: 10, cleanWindows: 1),
            "legacy loss doesn't count as raw loss — window reads clean")
    }

    func testNoViewersReadsCleanAndWindsDown() {
        let d = decide([:], state: State(groupSize: 10, cleanWindows: 1))
        XCTAssertEqual(d.state, State())
        XCTAssertTrue(d.gated.isEmpty)
    }

    // MARK: - Bitrate compensation

    func testCompensationScalesByNOverNPlusOne() {
        XCTAssertEqual(Server.fecCompensatedBitrate(11_000_000, groupSize: 10), 10_000_000)
        XCTAssertEqual(Server.fecCompensatedBitrate(8_000_000, groupSize: 7), 7_000_000)
        XCTAssertEqual(Server.fecCompensatedBitrate(6_000_000, groupSize: 5), 5_000_000)
    }

    func testCompensationIdentityWhenOff() {
        XCTAssertEqual(Server.fecCompensatedBitrate(6_000_000, groupSize: 0), 6_000_000)
    }

    func testCompensationClampedAtScaledFloor() {
        // The compensated rate can't sit below the adaptive floor's own
        // compensated equivalent, even for a bitrate at/below the floor.
        let floor = TransportTuning.adaptiveFloorMinBps
        XCTAssertEqual(Server.fecCompensatedBitrate(floor, groupSize: 10), floor * 10 / 11)
        XCTAssertEqual(
            Server.fecCompensatedBitrate(floor / 2, groupSize: 10), floor * 10 / 11,
            "sub-floor input clamps up to the scaled floor")
    }
}
