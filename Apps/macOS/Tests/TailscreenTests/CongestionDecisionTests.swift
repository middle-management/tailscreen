import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// Pure-decision tests for the receiver-feedback congestion controller
/// (`nextCongestionDecision`) and its fps ladder. Covers the loss-fraction
/// cut/hold/raise bands, the NACK-vs-PLI weighting, the fps-tier transitions
/// with hysteresis, and the legacy-PLI-input parity that keeps
/// `AdaptiveBitrateTests` valid unchanged.
final class CongestionDecisionTests: XCTestCase {
    private typealias Inputs = TailscaleScreenShareServer.CongestionInputs
    private typealias Decision = TailscaleScreenShareServer.CongestionDecision
    private let baseline = 10_000_000  // 10 Mbps; floor = 3 Mbps
    private let s: UInt64 = 1_000_000_000

    private func inputs(lossQ8: Int = 0, plis: Int = 0, current: Int, fps: Int = 60, elapsed: UInt64) -> Inputs {
        Inputs(
            lossFractionQ8: lossQ8, pliCount: plis, nackServed: 0, current: current,
            baseline: baseline, fpsTier: fps, elapsedSinceChangeNs: elapsed)
    }

    private func decide(_ i: Inputs) -> Decision {
        TailscaleScreenShareServer.nextCongestionDecision(i)
    }

    func testHeavyRRLossCutsBitrate() {
        // ~12 % loss (Q8 30 > 26), down-hysteresis elapsed, above floor.
        let d = decide(inputs(lossQ8: 30, current: baseline, elapsed: 5 * s))
        XCTAssertEqual(d.bitrate, 7_500_000)
        XCTAssertNil(d.fpsTier)
    }

    func testMidLossHolds() {
        // ~6 % loss (Q8 15) — not heavy, not clean → hold.
        XCTAssertEqual(decide(inputs(lossQ8: 15, current: baseline, elapsed: 30 * s)), .hold)
    }

    func testCleanWindowRaisesBitrate() {
        // < 2 % loss, below 60 % of baseline (6 Mbps), up-hysteresis elapsed.
        let d = decide(inputs(lossQ8: 2, current: 5_000_000, elapsed: 10 * s))
        XCTAssertEqual(d.bitrate, 5_500_000)
        XCTAssertNil(d.fpsTier)
    }

    func testNACKRecoveredLossWeighsHalfAPLI() {
        // 4 PLIs would cut, but 8 NACKs served halve the weight to 0 effective
        // PLIs; with low RR loss that's a hold, not a cut.
        let i = TailscaleScreenShareServer.CongestionInputs(
            lossFractionQ8: 0, pliCount: 4, nackServed: 8, current: baseline, baseline: baseline,
            fpsTier: 60, elapsedSinceChangeNs: 5 * s)
        XCTAssertEqual(decide(i), .hold)
    }

    func testLegacyPLIParityCut() {
        // No RR (Q8 0), 3 PLIs, down-ready → same −25 % as nextAdaptiveBitrate.
        let d = decide(inputs(plis: 3, current: baseline, elapsed: 5 * s))
        XCTAssertEqual(d.bitrate, 7_500_000)
        XCTAssertEqual(
            d.bitrate,
            TailscaleScreenShareServer.nextAdaptiveBitrate(
                worstPLIs: 3, current: baseline, baseline: baseline, elapsedSinceChangeNs: 5 * s))
    }

    func testLegacyPLIParityRaise() {
        let d = decide(inputs(plis: 0, current: 5_000_000, elapsed: 10 * s))
        XCTAssertEqual(
            d.bitrate,
            TailscaleScreenShareServer.nextAdaptiveBitrate(
                worstPLIs: 0, current: 5_000_000, baseline: baseline, elapsedSinceChangeNs: 10 * s))
    }

    func testFpsDownshiftWhenBitrateAtFloor() {
        // At the 3 Mbps floor with persistent loss → drop 60 → 30 (not bitrate).
        let d = decide(inputs(lossQ8: 30, current: 3_000_000, fps: 60, elapsed: 5 * s))
        XCTAssertNil(d.bitrate)
        XCTAssertEqual(d.fpsTier, 30)
        // And 30 → 15 on continued loss.
        let d2 = decide(inputs(lossQ8: 30, current: 3_000_000, fps: 30, elapsed: 5 * s))
        XCTAssertEqual(d2.fpsTier, 15)
        // 15 is the bottom rung — nothing more to give.
        let d3 = decide(inputs(lossQ8: 30, current: 3_000_000, fps: 15, elapsed: 5 * s))
        XCTAssertEqual(d3, .hold)
    }

    func testFpsRestoredBeforeBitrateClimbsPastSixtyPercent() {
        // Clean window at >= 60 % of baseline (6 Mbps) restores fps first.
        let d = decide(inputs(lossQ8: 0, current: 6_000_000, fps: 30, elapsed: 10 * s))
        XCTAssertNil(d.bitrate)
        XCTAssertEqual(d.fpsTier, 60)
        // Below 60 %, bitrate recovers and fps stays put.
        let d2 = decide(inputs(lossQ8: 0, current: 4_000_000, fps: 30, elapsed: 10 * s))
        XCTAssertNotNil(d2.bitrate)
        XCTAssertNil(d2.fpsTier)
    }

    func testNoChangeBeforeHysteresis() {
        XCTAssertEqual(decide(inputs(lossQ8: 30, current: baseline, elapsed: 4 * s)), .hold)
        XCTAssertEqual(decide(inputs(lossQ8: 0, current: 5_000_000, elapsed: 9 * s)), .hold)
    }

    func testClampsDownWhenCurrentExceedsBaseline() {
        let d = decide(inputs(current: 12_000_000, elapsed: 0))
        XCTAssertEqual(d.bitrate, baseline)
    }

    // MARK: - Review fixes

    func testRaiseFpsTierRespectsCap() {
        XCTAssertEqual(TailscaleScreenShareServer.raiseFpsTier(30, cap: 60), 60)
        XCTAssertEqual(TailscaleScreenShareServer.raiseFpsTier(15, cap: 30), 30)
        XCTAssertNil(
            TailscaleScreenShareServer.raiseFpsTier(30, cap: 30),
            "a 30 fps-capped session must never be raised to 60")
        XCTAssertNil(TailscaleScreenShareServer.raiseFpsTier(60, cap: 60))
    }

    func testCappedSessionNeverRaisesFpsAboveCap() {
        // 30 fps-capped session at tier 30, clean & recovered — must NOT jump to 60.
        let i = Inputs(
            lossFractionQ8: 0, pliCount: 0, nackServed: 0, current: 6_000_000, baseline: baseline,
            fpsTier: 30, fpsCap: 30, elapsedSinceChangeNs: 10 * s)
        let d = TailscaleScreenShareServer.nextCongestionDecision(i)
        XCTAssertNil(d.fpsTier, "must not raise fps above the session cap")
    }

    func testRRLossyViewerIsolatedNotGlobal() {
        // v1 reports 100 % RR loss but 0 PLIs; v2/v3 healthy. v1 must be
        // isolated (throttled) and the global inputs reflect only the healthy
        // viewers — a single lying viewer can't tank the shared rate.
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 0, "v2": 0, "v3": 0],
            lossQ8ByAddr: ["v1": 255, "v2": 2, "v3": 0],
            currentlyThrottled: [])
        XCTAssertEqual(gci.throttle, ["v1"], "the RR-lossy viewer must be isolated")
        XCTAssertEqual(gci.pliInput, 0)
        XCTAssertLessThanOrEqual(gci.lossQ8Input, 2, "global RR loss must reflect only healthy viewers")

        let d = decide(
            Inputs(
                lossFractionQ8: gci.lossQ8Input, pliCount: gci.pliInput, nackServed: 0,
                current: baseline, baseline: baseline, fpsTier: 60, fpsCap: 60,
                elapsedSinceChangeNs: 5 * s))
        XCTAssertNil(d.bitrate, "one lying viewer must not cut the shared rate")
        XCTAssertNil(d.fpsTier)
    }

    func testLegacyPLIOnlyStillReachesGlobal() {
        // No RR at all: a truly widespread PLI loss still drives the global cut
        // (regression: folding RR in must not swallow the PLI path).
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 5, "v2": 4],
            lossQ8ByAddr: [:],
            currentlyThrottled: [])
        XCTAssertTrue(gci.throttle.isEmpty, "widespread PLI loss isolates nobody")
        XCTAssertEqual(gci.pliInput, 5)
        XCTAssertEqual(gci.lossQ8Input, 0)
    }

    func testRecoveryAllowedWithNACKsServed() {
        // Low RR loss, 0 PLIs, but NACKs served this window — recovery must
        // still fire (the retransmits already repaired the loss).
        let i = Inputs(
            lossFractionQ8: 2, pliCount: 0, nackServed: 12, current: 5_000_000, baseline: baseline,
            fpsTier: 60, fpsCap: 60, elapsedSinceChangeNs: 10 * s)
        let d = TailscaleScreenShareServer.nextCongestionDecision(i)
        XCTAssertEqual(d.bitrate, 5_500_000, "served NACKs must not block recovery")
    }

    func testHoldsWhenNoBaseline() {
        let i = TailscaleScreenShareServer.CongestionInputs(
            lossFractionQ8: 99, pliCount: 9, nackServed: 0, current: 0, baseline: 0, fpsTier: 60,
            elapsedSinceChangeNs: 60 * s)
        XCTAssertEqual(TailscaleScreenShareServer.nextCongestionDecision(i), .hold)
    }
}
