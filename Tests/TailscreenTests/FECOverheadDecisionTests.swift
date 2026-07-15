import XCTest

@testable import Tailscreen

/// Pure-decision tests for the adaptive-FEC arm of the congestion sweep:
/// the RTT ∧ loss on-gate, the raw-loss group-size ladder, raw-loss
/// reconstruction from residual + recovered (the anti-oscillation term),
/// the two-clean-windows off-hysteresis, the per-viewer send gate, input
/// isolation (throttled/legacy viewers excluded), and the N/(N+1) encoder
/// compensation.
final class FECOverheadDecisionTests: XCTestCase {
    private typealias Server = TailscaleScreenShareServer
    private typealias State = TailscaleScreenShareServer.FECState
    private typealias Inputs = TailscaleScreenShareServer.FECInputs
    private typealias Sample = TailscaleScreenShareServer.FECViewerSample
    private let ms: UInt64 = 1_000_000

    private func inputs(
        rttMs: UInt64, residualQ8: Int = 0, recoveredQ8: Int = 0, state: State = State()
    ) -> Inputs {
        Inputs(rttNs: rttMs * ms, residualLossQ8: residualQ8, recoveredQ8: recoveredQ8, state: state)
    }

    // MARK: - On-gate

    func testLossyButFastPathStaysOff() {
        // ~3 % loss but RTT 100 ms < 150 ms: NACK beats render — no parity.
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 100, residualQ8: 8)), State())
    }

    func testSlowButCleanPathStaysOff() {
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 300, residualQ8: 2)), State())
    }

    func testGateBoundariesAreExclusive() {
        // Exactly 150 ms / exactly 2 % (Q8 5) do NOT gate on.
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 150, residualQ8: 8)), State())
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 5)), State())
    }

    func testSlowLossyPathGatesOn() {
        let next = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 8))
        XCTAssertEqual(next, State(groupSize: 10, cleanWindows: 0))
    }

    // MARK: - Loss ladder (raw loss → group size)

    func testLadderBands() {
        // 2–4 % → 10; 4–8 % → 7; > 8 % → 5. Band edges: Q8 10 (~3.9 %) is
        // still the light band, 11 crosses to medium; 20 medium, 21 heavy.
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 6)).groupSize, 10)
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 10)).groupSize, 10)
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 11)).groupSize, 7)
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 20)).groupSize, 7)
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 21)).groupSize, 5)
        XCTAssertEqual(Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 255)).groupSize, 5)
    }

    func testLadderReadjustsWhileOn() {
        // Loss worsens: on at N=10, raw ~6 % → step to 7.
        let on = State(groupSize: 10, cleanWindows: 0)
        XCTAssertEqual(
            Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 15, state: on)).groupSize, 7)
    }

    // MARK: - Anti-oscillation (the fecRecovered term)

    func testFECHidingAllLossStaysOn() {
        // Residual ≈ 0 because parity is repairing everything; the recovered
        // term reconstructs raw loss, so FEC must NOT gate off (which would
        // re-trigger the loss it's hiding).
        let on = State(groupSize: 10, cleanWindows: 0)
        let next = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 0, recoveredQ8: 8, state: on))
        XCTAssertEqual(next, State(groupSize: 10, cleanWindows: 0))
    }

    func testRecoveredTermCountsTowardOnGate() {
        // Same reconstruction on the on-gate: residual 1 % + recovered 2 %
        // crosses the 2 % raw gate.
        let next = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 3, recoveredQ8: 5))
        XCTAssertEqual(next.groupSize, 10)
    }

    // MARK: - Off-gate hysteresis

    func testTwoConsecutiveCleanWindowsGateOff() {
        let on = State(groupSize: 7, cleanWindows: 0)
        let afterOne = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 0, state: on))
        XCTAssertEqual(afterOne, State(groupSize: 7, cleanWindows: 1), "first clean window holds parity")
        let afterTwo = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 0, state: afterOne))
        XCTAssertEqual(afterTwo, State(), "second clean window gates off")
    }

    func testLossResetsCleanWindowCount() {
        let oneClean = State(groupSize: 10, cleanWindows: 1)
        let next = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 8, state: oneClean))
        XCTAssertEqual(next.cleanWindows, 0)
        XCTAssertEqual(next.groupSize, 10)
    }

    func testGrayZoneHoldsCurrentGroup() {
        // Raw loss between clean (< 1 %) and the ladder floor (≤ 2 %): not
        // clean, not ladder-worthy — hold the current group size.
        let on = State(groupSize: 7, cleanWindows: 1)
        let next = Server.fecOverheadDecision(inputs(rttMs: 200, residualQ8: 4, state: on))
        XCTAssertEqual(next, State(groupSize: 7, cleanWindows: 0))
    }

    // MARK: - Input assembly (isolation)

    func testThrottledAndLegacyViewersExcludedFromInputs() {
        let samples: [String: Sample] = [
            "good": Sample(rttNs: 60 * ms, residualLossQ8: 0, recovered: 0, fecCapable: true),
            "throttled": Sample(
                rttNs: 400 * ms, residualLossQ8: 60, recovered: 40, fecCapable: true, throttled: true),
            "legacy": Sample(rttNs: 500 * ms, residualLossQ8: 80, recovered: 0, fecCapable: false)
        ]
        let inputs = Server.fecDecisionInputs(samples: samples, expectedPackets: 1000, state: State())
        XCTAssertEqual(inputs.rttNs, 60 * ms, "throttled/legacy RTT must not leak into the decision")
        XCTAssertEqual(inputs.residualLossQ8, 0)
        XCTAssertEqual(inputs.recoveredQ8, 0)
        XCTAssertEqual(Server.fecOverheadDecision(inputs), State(), "one outlier can't force overhead on")
    }

    func testWorstOfEligibleViewersFeedsDecision() {
        let samples: [String: Sample] = [
            "ok": Sample(rttNs: 80 * ms, residualLossQ8: 1, recovered: 0, fecCapable: true),
            "bad": Sample(rttNs: 250 * ms, residualLossQ8: 9, recovered: 25, fecCapable: true)
        ]
        let inputs = Server.fecDecisionInputs(samples: samples, expectedPackets: 800, state: State())
        XCTAssertEqual(inputs.rttNs, 250 * ms)
        XCTAssertEqual(inputs.residualLossQ8, 9)
        XCTAssertEqual(inputs.recoveredQ8, Server.fecRecoveredQ8(recovered: 25, expectedPackets: 800))
        XCTAssertGreaterThan(Server.fecOverheadDecision(inputs).groupSize, 0)
    }

    func testRecoveredQ8Conversion() {
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 0, expectedPackets: 1000), 0)
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 10, expectedPackets: 1000), 2)  // 1 % ≈ Q8 2
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 500, expectedPackets: 1000), 128)
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 5000, expectedPackets: 1000), 255, "clamped")
        XCTAssertEqual(Server.fecRecoveredQ8(recovered: 10, expectedPackets: 0), 0, "no expected → no signal")
    }

    // MARK: - Per-viewer send gate

    func testViewerGateRequiresBothRTTAndLoss() {
        XCTAssertTrue(Server.fecViewerGate(rttNs: 200 * ms, rawLossQ8: 8))
        XCTAssertFalse(Server.fecViewerGate(rttNs: 100 * ms, rawLossQ8: 8), "fast path — NACK suffices")
        XCTAssertFalse(Server.fecViewerGate(rttNs: 200 * ms, rawLossQ8: 3), "clean link pays zero overhead")
        XCTAssertFalse(Server.fecViewerGate(rttNs: 150 * ms, rawLossQ8: 8), "boundary exclusive")
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
}
