import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// `TailscaleScreenShareServer.transportSummaryFields` — the sharer's
/// `transport.summary` row for one viewer and one sweep window.
///
/// The live sweep that records it cannot run here (it no-ops without a
/// capture helper attached, the same reason `AdaptiveBitrateTests` exist),
/// so the row itself is pinned as a pure function. The leg to read first is
/// the receiver-report freshness pair: the summary was added because a
/// share whose viewer's reports had quietly stopped arriving produced a
/// bundle indistinguishable from a clean one — the sweep decays a stale
/// report to "no loss" and the stats log line only fires on a nonzero count.
final class SharerTransportSummaryTests: XCTestCase {

    private typealias Server = TailscaleScreenShareServer

    private let window: UInt64 = 5_000_000_000
    private let share = Server.ShareTransportState(
        bitrateBps: 12_000_000, baselineBps: 20_000_000, fpsTier: 30, fecGroupSize: 8)

    private func fields(
        _ sample: Server.ViewerTransportSample, nowNs: UInt64 = 60_000_000_000,
        elapsedNs: UInt64? = nil
    ) -> [String: DiagnosticValue] {
        Server.transportSummaryFields(
            addr: "100.64.0.9:51820", sample: sample, share: share,
            window: Server.SummaryWindow(nowNs: nowNs, nominalNs: window, elapsedNs: elapsedNs ?? window))
    }

    /// `window_ms` is the interval the row actually covers, not the sweep's
    /// nominal window: the sweep sleeps for the window and then works, so
    /// the counters it drains span more than the window. Freshness stays
    /// judged against the nominal window, because that is what the sweep's
    /// own decay uses — the two durations answer different questions.
    func testWindowIsMeasuredWhileFreshnessStaysNominal() {
        let now: UInt64 = 60_000_000_000
        let sample = Server.ViewerTransportSample(lastRRAtNs: now - window + 1)
        let row = fields(sample, nowNs: now, elapsedNs: window + 340_000_000)
        XCTAssertEqual(row["window_ms"], .int(5340), "the measured interval")
        XCTAssertEqual(row["rr_fresh"], .bool(true), "fresh against the nominal window")
        XCTAssertEqual(fields(sample, nowNs: now)["window_ms"], .int(5000))
    }

    /// A viewer that never sent a receiver report says so — `rr_received`
    /// false, `rr_fresh` false, and NO `rr_age_ms`, because an age of zero
    /// would read as "just now", the opposite of the truth.
    func testNeverReportedViewerHasNoAgeAndIsNotFresh() {
        let row = fields(Server.ViewerTransportSample(lossFractionQ8: 0, lastRRAtNs: 0))
        XCTAssertEqual(row["rr_received"], .bool(false))
        XCTAssertEqual(row["rr_fresh"], .bool(false))
        XCTAssertNil(row["rr_age_ms"], "no report → no age, not age zero")
    }

    /// A report inside the window is fresh and its age is exact.
    func testFreshReportCarriesItsAge() {
        let now: UInt64 = 60_000_000_000
        let row = fields(
            Server.ViewerTransportSample(lossFractionQ8: 13, lastRRAtNs: now - 1_200_000_000), nowNs: now)
        XCTAssertEqual(row["rr_received"], .bool(true))
        XCTAssertEqual(row["rr_fresh"], .bool(true))
        XCTAssertEqual(row["rr_age_ms"], .int(1200))
        XCTAssertEqual(row["loss_q8"], .int(13), "the reported loss, undecayed")
    }

    /// **The case the summary exists for.** A viewer whose reports stopped
    /// arriving is still `rr_received` (it did report once) but no longer
    /// `rr_fresh`, and its last loss reading is still in the row rather than
    /// decayed to zero — the sweep's decay is the right input for the
    /// congestion decision and the wrong thing to record.
    func testStaleReportIsRecordedAsStaleNotAsClean() {
        let now: UInt64 = 60_000_000_000
        let row = fields(
            Server.ViewerTransportSample(lossFractionQ8: 40, lastRRAtNs: now - 3 * window), nowNs: now)
        XCTAssertEqual(row["rr_received"], .bool(true))
        XCTAssertEqual(row["rr_fresh"], .bool(false))
        XCTAssertEqual(row["rr_age_ms"], .int(15_000))
        XCTAssertEqual(row["loss_q8"], .int(40), "stale loss stays visible, not zeroed")
    }

    /// Exactly one window old is stale, one nanosecond short of it is fresh —
    /// the same `<` the sweep applies to its decay.
    func testFreshnessBoundaryMatchesTheSweep() {
        let now: UInt64 = 60_000_000_000
        XCTAssertEqual(
            fields(Server.ViewerTransportSample(lastRRAtNs: now - window + 1), nowNs: now)["rr_fresh"],
            .bool(true))
        XCTAssertEqual(
            fields(Server.ViewerTransportSample(lastRRAtNs: now - window), nowNs: now)["rr_fresh"],
            .bool(false))
    }

    /// A report stamped after `now` (the sweep's clock read before the report
    /// landed) is fresh with age zero rather than a wrapped enormous age.
    func testReportNewerThanNowIsFreshWithZeroAge() {
        let now: UInt64 = 60_000_000_000
        let row = fields(Server.ViewerTransportSample(lastRRAtNs: now + 5), nowNs: now)
        XCTAssertEqual(row["rr_fresh"], .bool(true))
        XCTAssertEqual(row["rr_age_ms"], .int(0))
    }

    /// Raw loss is residual plus what FEC and NACK recovered, against the
    /// viewer's own expected packet count — the number the FEC arm gates on.
    /// 13 Q8 residual + 16 recovered of 256 planned (16 Q8) → 29 Q8 raw, the
    /// same `fecRecoveredQ8` arithmetic the FEC arm applies.
    func testRawLossAddsRecoveriesAgainstOwnDenominator() {
        let row = fields(
            Server.ViewerTransportSample(
                lossFractionQ8: 13, lastRRAtNs: 1, fecRecovered: 10, nackRecovered: 6, packetsSent: 256))
        XCTAssertEqual(row["loss_q8"], .int(13))
        XCTAssertEqual(
            row["raw_loss_q8"],
            DiagnosticValue(13 + Server.fecRecoveredQ8(recovered: 16, expectedPackets: 256)))
        XCTAssertEqual(row["raw_loss_q8"], .int(29), "16/256 = 16 Q8 on top of the residual 13")
        XCTAssertEqual(row["fec_recovered"], .int(10))
        XCTAssertEqual(row["nack_recovered"], .int(6))
        XCTAssertEqual(row["packets_sent"], .int(256))
    }

    /// Raw loss saturates at 255 (100 %) rather than overflowing the Q8 range.
    func testRawLossClampsAtFull() {
        let row = fields(
            Server.ViewerTransportSample(lossFractionQ8: 250, lastRRAtNs: 1, fecRecovered: 100, packetsSent: 100))
        XCTAssertEqual(row["raw_loss_q8"], .int(255))
    }

    /// The percentage is the Q8 value rendered for a reader, one decimal.
    func testLossPercentIsDerivedFromQ8() {
        XCTAssertEqual(fields(Server.ViewerTransportSample(lossFractionQ8: 0))["loss_pct"], .double(0))
        XCTAssertEqual(fields(Server.ViewerTransportSample(lossFractionQ8: 255))["loss_pct"], .double(100))
        XCTAssertEqual(fields(Server.ViewerTransportSample(lossFractionQ8: 26))["loss_pct"], .double(10.2))
    }

    /// The share-wide state rides on every viewer's row, so one row explains
    /// the tier the viewer was being served at without a second lookup.
    func testShareStateAndUnitsAreCarried() {
        let row = fields(
            Server.ViewerTransportSample(
                pliCount: 3, rttNs: 47_500_000, lastRRAtNs: 1, nackServed: 12,
                droppedVideoFrames: 4, droppedAudioFrames: 1, health: .throttled, fecGated: true))
        XCTAssertEqual(row["addr"], .string("100.64.0.9:51820"))
        XCTAssertEqual(row["window_ms"], .int(5000))
        XCTAssertEqual(row["plis"], .int(3))
        XCTAssertEqual(row["rtt_ms"], .int(47), "nanoseconds → whole milliseconds")
        XCTAssertEqual(row["nack_served"], .int(12))
        XCTAssertEqual(row["video_drops_total"], .int(4))
        XCTAssertEqual(row["audio_drops_total"], .int(1))
        XCTAssertEqual(row["health"], .string("throttled"))
        XCTAssertEqual(row["fec_gated"], .bool(true))
        XCTAssertEqual(row["bitrate_kbps"], .int(12_000), "bits → kilobits")
        XCTAssertEqual(row["baseline_kbps"], .int(20_000))
        XCTAssertEqual(row["fps_tier"], .int(30))
        XCTAssertEqual(row["fec_group_size"], .int(8))
    }

    /// Every value is a flat scalar and every key is a stable `snake_case`
    /// identifier — the shape the bundle format and its readers depend on.
    /// A row on a clean window is exactly as complete as one on a bad
    /// window, which is what makes the two distinguishable at all.
    func testRowIsCompleteOnACleanWindow() {
        let clean = fields(Server.ViewerTransportSample(lastRRAtNs: 59_000_000_000))
        let bad = fields(
            Server.ViewerTransportSample(
                pliCount: 9, lossFractionQ8: 80, rttNs: 300_000_000, lastRRAtNs: 59_000_000_000,
                nackServed: 40, fecRecovered: 8, nackRecovered: 3, packetsSent: 500,
                droppedVideoFrames: 20, health: .degraded, fecGated: true))
        XCTAssertEqual(Set(clean.keys), Set(bad.keys), "same keys whether or not anything happened")
        for key in clean.keys {
            XCTAssertEqual(key, key.lowercased(), "\(key) is not lowercase")
            XCTAssertFalse(key.contains(" ") || key.contains("-"), "\(key) is not snake_case")
        }
    }
}
