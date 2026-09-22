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

    // MARK: - Missing receiver feedback
    //
    // The sweep decays a stale RR's loss to 0 so a viewer that reported badly
    // and went quiet can't pin the shared rate down. That leaves the decayed 0
    // and a genuinely clean 0 indistinguishable here, so the recovery arm read
    // a dead feedback path as a perfect link and kept climbing. `feedbackStale`
    // is the missing third state.

    /// The regression, stated as an inequality between two runs that differ in
    /// nothing else. Asserting only the stale case holds would pass against an
    /// implementation that never raises at all.
    func testMissingFeedbackSuppressesTheUpRamp() {
        var clean = inputs(current: 5_000_000, elapsed: 10 * s)
        XCTAssertEqual(decide(clean).bitrate, 5_500_000, "a clean window still recovers")
        clean.feedbackStale = true
        XCTAssertEqual(decide(clean), .hold, "silence is not a clean window")
    }

    /// Missing feedback must not CUT either. Nobody said the link is bad —
    /// nobody said anything — and cutting on silence would punish a viewer
    /// whose reports are merely late, every window, forever.
    func testMissingFeedbackDoesNotCut() {
        var i = inputs(current: 5_000_000, elapsed: 10 * s)
        i.feedbackStale = true
        let d = decide(i)
        XCTAssertNil(d.bitrate)
        XCTAssertNil(d.fpsTier)
    }

    /// Real loss still cuts while feedback is stale: the flag only ever
    /// subtracts from `clean`, and one viewer's silence must not shield
    /// another viewer's reported loss from the cut arm.
    func testMissingFeedbackDoesNotBlockACutForReportedLoss() {
        var i = inputs(lossQ8: 30, current: baseline, elapsed: 5 * s)
        i.feedbackStale = true
        XCTAssertEqual(decide(i).bitrate, 7_500_000)
    }

    /// The fps-recovery rung is gated on the same `clean`, so it must hold too
    /// — otherwise a stale-feedback session would freeze its bitrate and go on
    /// climbing frame rate, which costs the same bandwidth by another route.
    func testMissingFeedbackSuppressesTheFpsRecoveryRung() {
        var i = inputs(current: 8_000_000, fps: 30, elapsed: 10 * s)
        XCTAssertEqual(decide(i).fpsTier, 60, "a clean window restores fps first")
        i.feedbackStale = true
        XCTAssertEqual(decide(i), .hold)
    }

    /// Default-false, so every legacy PLI-only caller is byte-identical to
    /// before. `AdaptiveBitrateTests` depends on this.
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

    /// The safety rail, and the leg to read first. A viewer that never
    /// negotiated `.receiverReport` is silent BY DESIGN — legacy peers and
    /// every stream-transport viewer, whose caps mask drops NACK and FEC and
    /// which would otherwise be permanently stale. Reading their silence as
    /// missing feedback freezes the rate for the whole session, on a share
    /// where nothing is wrong.
    func testAViewerThatNeverNegotiatedReportsIsNeverStale() {
        XCTAssertFalse(stale(expects: false, reported: false, sinceWindows: 100))
        XCTAssertFalse(stale(expects: false, reported: true, sinceWindows: 100))
    }

    /// Reports are ~1 Hz against a ~5 s window, so one window of silence is
    /// many missed reports rather than an unlucky drop.
    func testAReportingViewerGoesStaleOneWindowAfterItsLastReport() {
        XCTAssertFalse(stale(reported: true, sinceWindows: 0.9))
        XCTAssertTrue(stale(reported: true, sinceWindows: 1.0), "boundary is inclusive")
        XCTAssertTrue(stale(reported: true, sinceWindows: 4))
    }

    /// A viewer that has never reported is measured from ADMISSION and gets
    /// two windows of slack: it may legitimately not have sent its first
    /// report yet, and treating a fresh join as stale would hold the rate
    /// down at the start of every share.
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

    /// Throttled viewers are excluded for the same reason — and against the
    /// same set — as their loss and PLI counts: the viewers this sweep
    /// decides to isolate, not the ones that happened to be isolated going
    /// in. A viewer being isolated is having its own link taken out of the
    /// shared decision, so its silence must not hold the rate everyone else
    /// sees. (PLIs and receiver reports are different control bytes, so a
    /// viewer can be losing loudly enough to isolate while its RRs have
    /// stopped arriving — which is exactly this case.)
    func testCongestionInputsIgnoresAStaleViewerItIsIsolating() {
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 0, "v2": 5], lossQ8ByAddr: [:], currentlyThrottled: [],
            feedbackStaleAddrs: ["v2"])
        XCTAssertEqual(gci.throttle, ["v2"], "precondition: v2 is the isolated viewer")
        XCTAssertFalse(gci.feedbackStale)
    }

    /// The default argument, so every existing caller of `congestionInputs`
    /// keeps reporting a live feedback path rather than an absent one.
    func testCongestionInputsIsNotStaleWithNobodyStale() {
        let gci = TailscaleScreenShareServer.congestionInputs(
            pliCounts: ["v1": 0], lossQ8ByAddr: [:], currentlyThrottled: [])
        XCTAssertFalse(gci.feedbackStale)
    }
}
