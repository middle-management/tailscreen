import TailscreenProtocol
import TailscreenSharer
import XCTest

/// Pure-decision tests for the adaptive-FEC arm of the congestion sweep
/// (`fecSweepDecision`): the strictly PER-VIEWER RTT ∧ loss gate (mixing
/// worst-RTT and worst-loss across different viewers must never switch FEC
/// on with nobody gated), the raw-loss group-size ladder, per-viewer
/// raw-loss reconstruction, the two-clean-windows off-hysteresis, and the
/// N/(N+1) encoder compensation with its floor clamp.
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

    /// NACK is repairing the loss so residual is low, but at high RTT the
    /// NACK-recovered count must still feed raw-loss reconstruction:
    /// residual 2 + (40/1000 → Q8 10) = 12 raw.
    func testNackMaskedLossStillGatesOn() {
        let d = decide(["v": sample(rttMs: 200, residualQ8: 2, nackRecovered: 40)])
        XCTAssertEqual(d.gated, ["v"])
        XCTAssertEqual(d.state.groupSize, 7)  // 12 raw > fecMidLossQ8 (10) → medium
    }

    /// The gate needs BOTH high RTT and high raw loss.
    func testNackRecoveryAloneOnFastPathStaysOff() {
        let d = decide(["v": sample(rttMs: 100, residualQ8: 2, nackRecovered: 40)])
        XCTAssertTrue(d.gated.isEmpty)
    }

    func testLossyButFastPathStaysOff() {
        let d = decide(["v": sample(rttMs: 100, residualQ8: 8)])
        XCTAssertEqual(d.state, State())
        XCTAssertTrue(d.gated.isEmpty)
    }

    func testSlowButCleanPathStaysOff() {
        let d = decide(["v": sample(rttMs: 300, residualQ8: 2)])
        XCTAssertEqual(d.state, State())
        XCTAssertTrue(d.gated.isEmpty)
    }

    /// Exactly 150ms / exactly 2% (Q8 5) do NOT gate on.
    func testGateBoundariesAreExclusive() {
        XCTAssertEqual(decide(["v": sample(rttMs: 150, residualQ8: 8)]).state, State())
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 5)]).state, State())
        XCTAssertFalse(Server.fecViewerGate(rttNs: 150 * ms, rawLossQ8: 8))
        XCTAssertFalse(Server.fecViewerGate(rttNs: 200 * ms, rawLossQ8: 5))
        XCTAssertTrue(Server.fecViewerGate(rttNs: 151 * ms, rawLossQ8: 6))
    }

    /// Taking worst-RTT and worst-loss over DIFFERENT viewers would say ON
    /// with an empty gated set — parity paid for but never received.
    func testCrossViewerMixingNeverTurnsFECOn() {
        let samples = [
            "slowClean": sample(rttMs: 200, residualQ8: 0),
            "fastLossy": sample(rttMs: 50, residualQ8: 13)
        ]
        let d = decide(samples)
        XCTAssertEqual(d.state, State(), "no single viewer qualifies — FEC must stay off")
        XCTAssertTrue(d.gated.isEmpty)
    }

    /// While already ON, loss is still present so N is held for a quick
    /// re-arm, but the gated set is EMPTY — compensation follows the gated
    /// set, not the held N.
    func testCrossViewerMixingFromOnStateHoldsWithoutGatedViewers() {
        let samples = [
            "slowClean": sample(rttMs: 200, residualQ8: 0),
            "fastLossy": sample(rttMs: 50, residualQ8: 13)
        ]
        let d = decide(samples, state: State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.state, State(groupSize: 10, cleanWindows: 0))
        XCTAssertTrue(d.gated.isEmpty, "held N with nobody gated ⇒ no parity, no compensation")
    }

    // MARK: - Loss ladder (raw loss → group size)

    /// 2-4% → 10; 4-8% → 7; >8% → 5.
    func testLadderBands() {
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 6)]).state.groupSize, 10)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 10)]).state.groupSize, 10)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 11)]).state.groupSize, 7)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 20)]).state.groupSize, 7)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 21)]).state.groupSize, 5)
        XCTAssertEqual(decide(["v": sample(rttMs: 200, residualQ8: 255)]).state.groupSize, 5)
    }

    func testLadderReadjustsWhileOn() {
        let on = State(groupSize: 10, cleanWindows: 0)
        let d = decide(["v": sample(rttMs: 200, residualQ8: 15)], state: on)
        XCTAssertEqual(d.state.groupSize, 7)
        XCTAssertEqual(d.gated, ["v"])
    }

    func testLadderFollowsWorstGatedViewer() {
        let samples = [
            "mild": sample(rttMs: 200, residualQ8: 7),
            "bad": sample(rttMs: 300, residualQ8: 25)
        ]
        let d = decide(samples)
        XCTAssertEqual(d.state.groupSize, 5)
        XCTAssertEqual(d.gated, ["mild", "bad"])
    }

    // MARK: - Anti-oscillation (the fecRecovered term)

    /// Residual ≈ 0 because parity is repairing everything; the recovered
    /// term reconstructs raw loss, so FEC must NOT gate off.
    func testFECHidingAllLossStaysOn() {
        let on = State(groupSize: 10, cleanWindows: 0)
        let d = decide(
            ["v": sample(rttMs: 200, residualQ8: 0, recovered: 30, expected: 1000)], state: on)
        XCTAssertEqual(d.state, State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.gated, ["v"], "a viewer whose parity is doing work keeps its parity")
    }

    func testRecoveredTermCountsTowardOnGate() {
        let d = decide(["v": sample(rttMs: 200, residualQ8: 3, recovered: 15, expected: 1000)])
        XCTAssertEqual(d.state.groupSize, 10)
        XCTAssertEqual(d.gated, ["v"])
    }

    // MARK: - Per-viewer denominators (recovered → raw loss)

    /// Two viewers each recovering ~3% of their OWN stream: per-viewer raw
    /// loss is ~3% each, NOT 6% summed against one stream.
    func testMultiViewerRecoveriesDoNotInflate() {
        let samples = [
            "a": sample(rttMs: 200, residualQ8: 0, recovered: 30, expected: 1000),
            "b": sample(rttMs: 250, residualQ8: 0, recovered: 30, expected: 1000)
        ]
        let d = decide(samples, state: State(groupSize: 10, cleanWindows: 0))
        XCTAssertEqual(d.state.groupSize, 10, "summing recoveries across viewers over-ladders overhead")
        XCTAssertEqual(d.gated, ["a", "b"])
    }

    /// A throttled viewer's small denominator (40 packets, not ~1000) must
    /// keep its gate stable — divided by the template-stream count instead,
    /// it would read ~0.05% and drop the gate, causing an oscillation.
    func testThrottledViewerGateStableAgainstOwnDenominator() {
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

    /// Raw loss between clean and the gate: not clean, nobody gated —
    /// hold N for a quick re-arm.
    func testGrayZoneHoldsCurrentGroupWithEmptyGate() {
        let on = State(groupSize: 7, cleanWindows: 1)
        let d = decide(["v": sample(rttMs: 200, residualQ8: 4)], state: on)
        XCTAssertEqual(d.state, State(groupSize: 7, cleanWindows: 0))
        XCTAssertTrue(d.gated.isEmpty)
    }

    // MARK: - Legacy exclusion

    /// A non-`.fec` viewer, however lossy/slow, is invisible to the FEC arm.
    func testLegacyViewersNeverGateOrDriveTheDecision() {
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
        let floor = TransportTuning.adaptiveFloorMinBps
        XCTAssertEqual(Server.fecCompensatedBitrate(floor, groupSize: 10), floor * 10 / 11)
        XCTAssertEqual(
            Server.fecCompensatedBitrate(floor / 2, groupSize: 10), floor * 10 / 11,
            "sub-floor input clamps up to the scaled floor")
    }
}
