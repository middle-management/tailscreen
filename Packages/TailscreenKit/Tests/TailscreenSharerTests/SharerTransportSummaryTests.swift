import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// `TailscaleScreenShareServer.transportSummaryFields` — the sharer's
/// `transport.summary` row for one viewer and one sweep window. Pinned as a
/// pure function since the live sweep can't run here. Read the
/// receiver-report freshness pair first: a viewer's stopped reports used to
/// produce a bundle indistinguishable from a clean one, since the sweep
/// decays a stale report to "no loss".
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

    /// `window_ms` is the interval actually covered, not the sweep's
    /// nominal window (which sleeps then works, so counters span more).
    /// Freshness stays judged against the nominal window, matching the
    /// sweep's own decay.
    func testWindowIsMeasuredWhileFreshnessStaysNominal() {
        let now: UInt64 = 60_000_000_000
        let sample = Server.ViewerTransportSample(lastRRAtNs: now - window + 1)
        let row = fields(sample, nowNs: now, elapsedNs: window + 340_000_000)
        XCTAssertEqual(row["window_ms"], .int(5340), "the measured interval")
        XCTAssertEqual(row["rr_fresh"], .bool(true), "fresh against the nominal window")
        XCTAssertEqual(fields(sample, nowNs: now)["window_ms"], .int(5000))
    }

    /// No `rr_age_ms` for a viewer that never reported — age zero would
    /// read as "just now".
    func testNeverReportedViewerHasNoAgeAndIsNotFresh() {
        let row = fields(Server.ViewerTransportSample(lossFractionQ8: 0, lastRRAtNs: 0))
        XCTAssertEqual(row["rr_received"], .bool(false))
        XCTAssertEqual(row["rr_fresh"], .bool(false))
        XCTAssertNil(row["rr_age_ms"], "no report → no age, not age zero")
    }

    func testFreshReportCarriesItsAge() {
        let now: UInt64 = 60_000_000_000
        let row = fields(
            Server.ViewerTransportSample(lossFractionQ8: 13, lastRRAtNs: now - 1_200_000_000), nowNs: now)
        XCTAssertEqual(row["rr_received"], .bool(true))
        XCTAssertEqual(row["rr_fresh"], .bool(true))
        XCTAssertEqual(row["rr_age_ms"], .int(1200))
        XCTAssertEqual(row["loss_q8"], .int(13), "the reported loss, undecayed")
    }

    /// A viewer whose reports stopped is still `rr_received` but no longer
    /// `rr_fresh`, with its last loss reading intact rather than decayed —
    /// the decay is right for the congestion decision, wrong to record.
    func testStaleReportIsRecordedAsStaleNotAsClean() {
        let now: UInt64 = 60_000_000_000
        let row = fields(
            Server.ViewerTransportSample(lossFractionQ8: 40, lastRRAtNs: now - 3 * window), nowNs: now)
        XCTAssertEqual(row["rr_received"], .bool(true))
        XCTAssertEqual(row["rr_fresh"], .bool(false))
        XCTAssertEqual(row["rr_age_ms"], .int(15_000))
        XCTAssertEqual(row["loss_q8"], .int(40), "stale loss stays visible, not zeroed")
    }

    /// Exactly one window old is stale; one nanosecond short is fresh.
    func testFreshnessBoundaryMatchesTheSweep() {
        let now: UInt64 = 60_000_000_000
        XCTAssertEqual(
            fields(Server.ViewerTransportSample(lastRRAtNs: now - window + 1), nowNs: now)["rr_fresh"],
            .bool(true))
        XCTAssertEqual(
            fields(Server.ViewerTransportSample(lastRRAtNs: now - window), nowNs: now)["rr_fresh"],
            .bool(false))
    }

    /// A report stamped after `now` is fresh with age zero rather than a
    /// wrapped enormous age.
    func testReportNewerThanNowIsFreshWithZeroAge() {
        let now: UInt64 = 60_000_000_000
        let row = fields(Server.ViewerTransportSample(lastRRAtNs: now + 5), nowNs: now)
        XCTAssertEqual(row["rr_fresh"], .bool(true))
        XCTAssertEqual(row["rr_age_ms"], .int(0))
    }

    /// Raw loss is residual plus recoveries against the viewer's own
    /// expected packet count, the same arithmetic the FEC arm applies.
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

    func testRawLossClampsAtFull() {
        let row = fields(
            Server.ViewerTransportSample(lossFractionQ8: 250, lastRRAtNs: 1, fecRecovered: 100, packetsSent: 100))
        XCTAssertEqual(row["raw_loss_q8"], .int(255))
    }

    func testLossPercentIsDerivedFromQ8() {
        XCTAssertEqual(fields(Server.ViewerTransportSample(lossFractionQ8: 0))["loss_pct"], .double(0))
        XCTAssertEqual(fields(Server.ViewerTransportSample(lossFractionQ8: 255))["loss_pct"], .double(100))
        XCTAssertEqual(fields(Server.ViewerTransportSample(lossFractionQ8: 26))["loss_pct"], .double(10.2))
    }

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

    /// A row on a clean window is exactly as complete as one on a bad
    /// window — what makes the two distinguishable at all.
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

    // MARK: - Inbound audio

    /// The upstream half: without these, "the sharer cannot hear me" left
    /// no trace.
    func testInboundAudioIsCountedOnTheRow() {
        let row = fields(
            Server.ViewerTransportSample(audioPacketsReceived: 250, audioPacketsRejected: 0))
        XCTAssertEqual(row["audio_packets_in"], .int(250))
        XCTAssertEqual(row["audio_rejected_in"], .int(0))
    }

    /// Rejected is its own number, not folded into accepted — the anti-spoof
    /// gate looks like silence from the sharer's seat while the viewer's own
    /// bundle shows it sending steadily.
    func testRejectedAudioIsDistinguishableFromAcceptedAudio() {
        let spoofed = fields(
            Server.ViewerTransportSample(audioPacketsReceived: 0, audioPacketsRejected: 250))
        let silent = fields(
            Server.ViewerTransportSample(audioPacketsReceived: 0, audioPacketsRejected: 0))
        XCTAssertEqual(spoofed["audio_packets_in"], silent["audio_packets_in"])
        XCTAssertNotEqual(
            spoofed["audio_rejected_in"], silent["audio_rejected_in"],
            "a viewer whose audio is being refused must not read as a viewer saying nothing")
    }

    // MARK: - Annotations

    func testAnnotationRowCarriesTheThreeOutcomes() {
        let row = Server.annotationSummaryFields(
            counters: Server.AnnotationCounters(applied: 7, dropped: 2, relayed: 5),
            windowNs: window)
        XCTAssertEqual(row["applied"], .int(7))
        XCTAssertEqual(row["dropped"], .int(2))
        XCTAssertEqual(row["relayed"], .int(5))
        XCTAssertEqual(row["window_ms"], .int(5000))
    }

    /// Unlike `transport.summary`, a window with no annotations means
    /// nobody drew, so it records nothing rather than a row of zeros.
    func testEmptyWindowIsRecognisedAsEmpty() {
        XCTAssertTrue(Server.AnnotationCounters().isEmpty)
        XCTAssertFalse(Server.AnnotationCounters(applied: 1).isEmpty)
        XCTAssertFalse(Server.AnnotationCounters(dropped: 1).isEmpty)
        XCTAssertFalse(Server.AnnotationCounters(relayed: 1).isEmpty)
    }

    /// A dropped-only window (ops arriving and being refused) is a row,
    /// not silence.
    func testDroppedOnlyWindowStillRecords() {
        let counters = Server.AnnotationCounters(applied: 0, dropped: 4, relayed: 0)
        XCTAssertFalse(counters.isEmpty)
        let row = Server.annotationSummaryFields(counters: counters, windowNs: window)
        XCTAssertEqual(row["applied"], .int(0))
        XCTAssertEqual(row["dropped"], .int(4))
    }
}
