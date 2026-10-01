import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// `UplinkStats.uplinkSummaryFields` and `shouldRecordUplinkSummary` — the
/// `audio.uplink.summary` row. Read `testTheCaptureChainIsOnTheRow` first: a
/// voice arriving muffled at the far end used to leave no evidence here at all,
/// and the format half is the point.
final class UplinkSummaryTests: XCTestCase {

    private let window: UInt64 = 5_000_000_000

    private func context(
        capturing: Bool = true,
        muted: Bool = false,
        rate: Double = 48_000,
        channels: Int = 1,
        voiceProcessing: Bool = false,
        peak: Float = 0.4,
        rms: Double = 0.1,
        bitrate: Int = 64_000
    ) -> UplinkStats.CaptureContext {
        UplinkStats.CaptureContext(
            capturing: capturing,
            muted: muted,
            captureSampleRate: rate,
            captureChannels: channels,
            voiceProcessing: voiceProcessing,
            peakLevel: peak,
            rmsLevel: rms,
            encoderBitrate: bitrate)
    }

    // MARK: - The reason this exists

    /// The facts a "you sounded wrong" report needs and that nothing recorded.
    func testTheCaptureChainIsOnTheRow() {
        let row = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window,
            context: context(rate: 44_100, channels: 3, voiceProcessing: true))
        XCTAssertEqual(row["capture_hz"], .int(44_100))
        XCTAssertEqual(row["capture_channels"], .int(3))
        XCTAssertEqual(row["resampled"], .bool(true))
        XCTAssertEqual(row["voice_processing"], .bool(true))
    }

    /// A row every window while capture runs, whether or not a counter moved —
    /// the same rule as `audio.summary`, for the same reason: a voice that
    /// sounds wrong while the counters sit still is the case this is for.
    func testARowIsRecordedEvenWhenNothingMoved() {
        XCTAssertTrue(UplinkStats.shouldRecordUplinkSummary(context: context()))
        let row = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context())
        XCTAssertEqual(row["frames_encoded"], .int(0))
        XCTAssertEqual(row["encode_failures"], .int(0))
    }

    func testNoCaptureMeansNoRow() {
        XCTAssertFalse(UplinkStats.shouldRecordUplinkSummary(context: context(capturing: false)))
    }

    /// Muted still records. "They cannot hear me" and "I was muted" are the
    /// same bundle without this.
    func testAMutedWindowStillRecords() {
        XCTAssertTrue(UplinkStats.shouldRecordUplinkSummary(context: context(muted: true)))
        let row = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context(muted: true))
        XCTAssertEqual(row["muted"], .bool(true))
    }

    // MARK: - Resampling is derived, not claimed

    /// `resampled` must agree with the rate on the same row — two fields that
    /// can disagree is worse than one.
    func testResamplingFollowsTheRate() {
        XCTAssertEqual(context(rate: 48_000).resampling, false)
        XCTAssertEqual(context(rate: 44_100).resampling, true)
        XCTAssertEqual(context(rate: 16_000).resampling, true)
        XCTAssertEqual(context(rate: 0).resampling, false, "unknown is not resampling")
    }

    /// Before the first buffer the rate is genuinely unknown, and a zero would
    /// read as "0 Hz, no channels" rather than "nobody has looked yet".
    func testAnUnknownFormatIsAbsentRatherThanZero() {
        let row = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context(rate: 0, channels: 0))
        XCTAssertNil(row["capture_hz"])
        XCTAssertNil(row["capture_channels"])
        XCTAssertEqual(row["resampled"], .bool(false))
    }

    // MARK: - Deltas and gauges

    func testCountersAreDeltasNotTotals() {
        var previous = UplinkStats()
        previous.framesEncoded = 1000
        previous.bytesEncoded = 160_000
        previous.encodeFailures = 2

        var now = previous
        now.framesEncoded = 1250
        now.bytesEncoded = 200_000
        now.encodeFailures = 2

        let row = now.uplinkSummaryFields(
            since: previous, windowNs: window, context: context())
        XCTAssertEqual(row["frames_encoded"], .int(250))
        XCTAssertEqual(row["bytes_encoded"], .int(40_000))
        XCTAssertEqual(row["encode_failures"], .int(0))
    }

    /// The achieved bitrate beside the configured one. An encoder quietly
    /// producing a fraction of what it was asked for is a muffled voice, and
    /// `encoder_kbps` alone would report it as healthy.
    func testAchievedBitrateIsReportedBesideTheConfiguredOne() {
        var now = UplinkStats()
        now.bytesEncoded = 40_000  // 320 kbit over 5 s → 64 kbps
        let row = now.uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context(bitrate: 64_000))
        XCTAssertEqual(row["bitrate_kbps"], .int(64))
        XCTAssertEqual(row["encoder_kbps"], .int(64))

        var starved = UplinkStats()
        starved.bytesEncoded = 5_000
        let thin = starved.uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context(bitrate: 64_000))
        XCTAssertEqual(thin["bitrate_kbps"], .int(8))
        XCTAssertEqual(
            thin["encoder_kbps"], .int(64),
            "the configured value must not be back-derived from what was produced")
    }

    /// Levels are per-window gauges supplied by the host, not counters, so two
    /// snapshots can never produce them — the host drains them.
    func testLevelsAreRoundedGauges() {
        let row = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window,
            context: context(peak: 0.98765, rms: 0.12345))
        XCTAssertEqual(row["peak_level"], .double(0.988))
        XCTAssertEqual(row["rms_level"], .double(0.123))
    }

    /// A live microphone delivering silence is a distinct failure from a muted
    /// one, and both have to be readable off one row.
    func testASilentLiveMicrophoneIsDistinguishableFromAMutedOne() {
        let silent = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window,
            context: context(muted: false, peak: 0, rms: 0))
        XCTAssertEqual(silent["muted"], .bool(false))
        XCTAssertEqual(silent["peak_level"], .double(0))

        let muted = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window,
            context: context(muted: true, peak: 0, rms: 0))
        XCTAssertNotEqual(silent["muted"], muted["muted"])
    }

    // MARK: - Shape

    func testCleanAndBadWindowsCarryTheSameKeys() {
        var bad = UplinkStats()
        bad.encodeFailures = 9
        bad.clippedBuffers = 44
        bad.packetsWithheld = 7

        let clean = UplinkStats().uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context())
        let noisy = bad.uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context())
        XCTAssertEqual(Set(clean.keys), Set(noisy.keys))
        for key in clean.keys {
            XCTAssertEqual(key, key.lowercased(), "\(key) is not lowercase")
            XCTAssertFalse(key.contains(" ") || key.contains("-"), "\(key) is not snake_case")
        }
    }

    func testWithheldAndClippingAreCounted() {
        var now = UplinkStats()
        now.packetsWithheld = 7
        now.clippedBuffers = 44
        let row = now.uplinkSummaryFields(
            since: UplinkStats(), windowNs: window, context: context())
        XCTAssertEqual(row["withheld"], .int(7))
        XCTAssertEqual(row["clipped"], .int(44))
    }
    // MARK: - The counters, across threads

    /// `takeUplinkStats()` is read from the host's summary clock while `ingest`
    /// runs on the capture thread — a second thread on state the type otherwise
    /// calls single-threaded, and without an overlapping test `linux-tsan`
    /// watches nothing. Asserts only interleaving-independent facts.
    func testStatsAreSafeToDrainWhileIngesting() throws {
        struct Observed {
            var finished = false
            var highestFrames = 0
            var wentBackwards = false
            var peakTooLoud = false
        }
        let observed = Guarded(Observed())
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        let format = AudioInputFormat.wire
        let frame = [Float](repeating: 0.25, count: OpusVoiceEncoder.frameSamples)
        let pushes = 200

        let readers = DispatchGroup()
        for _ in 0..<3 {
            DispatchQueue.global().async(group: readers) {
                // Monotonicity is per reader, in its own program order. Two
                // readers racing may legitimately see 50 and then 40.
                var lastSeen = 0
                while !observed.withLock({ $0.finished }) {
                    let drained = pipeline.takeUplinkStats()
                    _ = pipeline.capturedFormat
                    let backwards = drained.stats.framesEncoded < lastSeen
                    lastSeen = drained.stats.framesEncoded
                    observed.withLock {
                        if backwards { $0.wentBackwards = true }
                        $0.highestFrames = max($0.highestFrames, lastSeen)
                        if drained.peak > 0.26 { $0.peakTooLoud = true }
                    }
                }
            }
        }

        // The capture thread stays serial, as the backend contract requires.
        DispatchQueue(label: "capture").sync {
            for _ in 0..<pushes { pipeline.ingest(frame, format: format) }
        }
        observed.withLock { $0.finished = true }
        readers.wait()

        let final = pipeline.takeUplinkStats()
        XCTAssertEqual(final.stats.framesEncoded, pushes, "every frame pushed must be counted once")
        XCTAssertGreaterThan(final.stats.bytesEncoded, 0)
        XCTAssertEqual(final.stats.encodeFailures, 0)
        observed.withLock {
            XCTAssertFalse($0.wentBackwards, "a cumulative counter must never go backwards")
            XCTAssertFalse($0.peakTooLoud, "a drained peak must never exceed the loudest sample fed")
        }
    }
}
