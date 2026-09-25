import TailscreenSharer
import XCTest

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

    /// v1 reports 100% RR loss but 0 PLIs; v2/v3 healthy. v1 must be
    /// isolated, and global inputs reflect only the healthy viewers.
    func testRRLossyViewerIsolatedNotGlobal() {
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

    /// No RR at all: widespread PLI loss must still drive the global cut —
    /// folding RR in must not swallow the PLI path.
    func testLegacyPLIOnlyStillReachesGlobal() {
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 5, "v2": 4],
            lossQ8ByAddr: [:],
            currentlyThrottled: [])
        XCTAssertTrue(gci.throttle.isEmpty, "widespread PLI loss isolates nobody")
        XCTAssertEqual(gci.pliInput, 5)
        XCTAssertEqual(gci.lossQ8Input, 0)
    }

    /// NACKs served this window already repaired the loss, so recovery
    /// must still fire.
    func testRecoveryAllowedWithNACKsServed() {
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

    // MARK: - Missing receiver feedback
    //
    // The sweep decays a stale RR's loss to 0, indistinguishable from a
    // genuinely clean 0 — so the recovery arm read a dead feedback path as
    // a perfect link. `feedbackStale` is the missing third state.

    /// Stated as an inequality between two runs differing in nothing else,
    /// so an implementation that never raises can't pass by accident.
    func testMissingFeedbackSuppressesTheUpRamp() {
        var clean = inputs(current: 5_000_000, elapsed: 10 * s)
        XCTAssertEqual(decide(clean).bitrate, 5_500_000, "a clean window still recovers")
        clean.feedbackStale = true
        XCTAssertEqual(decide(clean), .hold, "silence is not a clean window")
    }

    /// Missing feedback must not CUT either — cutting on silence would
    /// punish a viewer whose reports are merely late, forever.
    func testMissingFeedbackDoesNotCut() {
        var i = inputs(current: 5_000_000, elapsed: 10 * s)
        i.feedbackStale = true
        let d = decide(i)
        XCTAssertNil(d.bitrate)
        XCTAssertNil(d.fpsTier)
    }

    /// One viewer's silence must not shield another's reported loss from
    /// the cut arm.
    func testMissingFeedbackDoesNotBlockACutForReportedLoss() {
        var i = inputs(lossQ8: 30, current: baseline, elapsed: 5 * s)
        i.feedbackStale = true
        XCTAssertEqual(decide(i).bitrate, 7_500_000)
    }

    /// The fps-recovery rung is gated on the same `clean`, or a
    /// stale-feedback session would climb frame rate instead of bitrate.
    func testMissingFeedbackSuppressesTheFpsRecoveryRung() {
        var i = inputs(current: 8_000_000, fps: 30, elapsed: 10 * s)
        XCTAssertEqual(decide(i).fpsTier, 60, "a clean window restores fps first")
        i.feedbackStale = true
        XCTAssertEqual(decide(i), .hold)
    }

    /// Default-false so every legacy PLI-only caller is byte-identical.
    func testFeedbackStaleDefaultsToFalse() {
        let i = Inputs(
            lossFractionQ8: 0, pliCount: 0, nackServed: 0, current: 5_000_000,
            baseline: baseline, fpsTier: 60, elapsedSinceChangeNs: 10 * s)
        XCTAssertFalse(i.feedbackStale)
        XCTAssertEqual(decide(i).bitrate, 5_500_000)
    }

    // MARK: - feedbackIsStale

    private func stale(
        expects: Bool = true, reported: Bool, sinceWindows: Double
    ) -> Bool {
        TailscaleScreenShareServer.feedbackIsStale(
            expectsReports: expects, hasReported: reported,
            sinceNs: UInt64(sinceWindows * 5_000_000_000), windowNs: 5 * s)
    }

    /// A viewer that never negotiated `.receiverReport` is silent BY
    /// DESIGN — legacy/stream-transport peers would otherwise be
    /// permanently stale, freezing the rate on a share where nothing is wrong.
    func testAViewerThatNeverNegotiatedReportsIsNeverStale() {
        XCTAssertFalse(stale(expects: false, reported: false, sinceWindows: 100))
        XCTAssertFalse(stale(expects: false, reported: true, sinceWindows: 100))
    }

    func testAReportingViewerGoesStaleOneWindowAfterItsLastReport() {
        XCTAssertFalse(stale(reported: true, sinceWindows: 0.9))
        XCTAssertTrue(stale(reported: true, sinceWindows: 1.0), "boundary is inclusive")
        XCTAssertTrue(stale(reported: true, sinceWindows: 4))
    }

    /// A viewer that has never reported is measured from admission and
    /// gets two windows of slack, or a fresh join would hold the rate down.
    func testAViewerThatHasNeverReportedGetsGraceFromAdmission() {
        XCTAssertFalse(stale(reported: false, sinceWindows: 1.5))
        XCTAssertTrue(stale(reported: false, sinceWindows: 2.0))
    }

    // MARK: - congestionInputs folding

    func testCongestionInputsReportsAnyNonThrottledStaleViewer() {
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 0, "v2": 0], lossQ8ByAddr: [:], currentlyThrottled: [],
            feedbackStaleAddrs: ["v2"])
        XCTAssertTrue(gci.feedbackStale)
    }

    /// A viewer being isolated has its own link taken out of the shared
    /// decision, so its silence must not hold the rate everyone else sees.
    func testCongestionInputsIgnoresAStaleViewerItIsIsolating() {
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 0, "v2": 5], lossQ8ByAddr: [:], currentlyThrottled: [],
            feedbackStaleAddrs: ["v2"])
        XCTAssertEqual(gci.throttle, ["v2"], "precondition: v2 is the isolated viewer")
        XCTAssertFalse(gci.feedbackStale)
    }

    func testCongestionInputsIsNotStaleWithNobodyStale() {
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 0], lossQ8ByAddr: [:], currentlyThrottled: [])
        XCTAssertFalse(gci.feedbackStale)
    }
}
