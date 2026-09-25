import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// `VoiceStats.audioSummaryFields` and `shouldRecordSummary` — the
/// `audio.summary` row and the rule for when there is one. Previously
/// counters reached a bundle only through a log line gated on "at most once
/// a minute, and only if a counter moved", so a call that sounded wrong
/// while counters sat still produced nothing at all. Read
/// `testARowIsRecordedEvenWhenNothingMoved` first — it is the whole point.
final class AudioSummaryTests: XCTestCase {

    private let window: UInt64 = 5_000_000_000

    private func context(
        voiceStreams: Int = 1,
        systemAudio: Bool = false,
        micOn: Bool = false,
        queueTracked: Bool = true,
        outputDevice: String? = "MacBook Pro Speakers"
    ) -> VoiceStats.PlaybackContext {
        VoiceStats.PlaybackContext(
            voiceStreams: voiceStreams,
            systemAudioPlaying: systemAudio,
            microphoneOn: micOn,
            jitterTargetDepth: 3,
            outputDevice: outputDevice,
            playbackQueueTracked: queueTracked)
    }

    // MARK: - The reason this exists

    func testARowIsRecordedEvenWhenNothingMoved() {
        let stats = VoiceStats()
        let row = stats.audioSummaryFields(since: stats, windowNs: window, context: context())
        XCTAssertEqual(row["concealed"], .int(0))
        XCTAssertEqual(row["clamped"], .int(0))
        XCTAssertEqual(row["voice_streams"], .int(1))
    }

    func testCleanAndBadWindowsCarryTheSameKeys() {
        var bad = VoiceStats()
        bad.concealedFrames = 40
        bad.discontinuities = 3
        bad.overrunDrops = 12
        bad.underruns = 5
        bad.clampedBuffers = 70
        bad.systemAudioClampedBuffers = 9
        bad.smoothedJitterMs = 41.27

        let clean = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context())
        let noisy = bad.audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context())
        XCTAssertEqual(Set(clean.keys), Set(noisy.keys))
        for key in clean.keys {
            XCTAssertEqual(key, key.lowercased(), "\(key) is not lowercase")
            XCTAssertFalse(key.contains(" ") || key.contains("-"), "\(key) is not snake_case")
        }
    }

    // MARK: - Deltas

    func testCountersAreDeltasNotTotals() {
        var previous = VoiceStats()
        previous.concealedFrames = 100
        previous.clampedBuffers = 20
        previous.underruns = 4

        var now = previous
        now.concealedFrames = 130
        now.clampedBuffers = 21
        now.underruns = 4

        let row = now.audioSummaryFields(since: previous, windowNs: window, context: context())
        XCTAssertEqual(row["concealed"], .int(30))
        XCTAssertEqual(row["clamped"], .int(1))
        XCTAssertEqual(row["underruns"], .int(0))
    }

    /// Jitter is a gauge, not a counter.
    func testJitterIsReportedAsItStandsAndRounded() {
        var now = VoiceStats()
        now.smoothedJitterMs = 12.34
        var previous = VoiceStats()
        previous.smoothedJitterMs = 99
        let row = now.audioSummaryFields(since: previous, windowNs: window, context: context())
        XCTAssertEqual(row["jitter_ms"], .double(12.3))
    }

    /// The two clip for different reasons: voice alone says the stream
    /// arrived hot; both together say the host's output mixer is summing
    /// them past full scale.
    func testSystemAudioClippingIsCountedApartFromVoice() {
        var now = VoiceStats()
        now.systemAudioClampedBuffers = 11
        let row = now.audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context(systemAudio: true))
        XCTAssertEqual(row["sys_clamped"], .int(11))
        XCTAssertEqual(row["clamped"], .int(0), "voice did not clip; only system audio did")
        XCTAssertEqual(row["system_audio"], .bool(true))
    }

    // MARK: - What was playing

    /// Without context, "concealed 0, clamped 0" is equally true of a clean
    /// call and one distorting somewhere the voice path can't see.
    func testContextIsCarriedOnTheRow() {
        let row = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window,
            context: context(voiceStreams: 2, systemAudio: true, micOn: true))
        XCTAssertEqual(row["voice_streams"], .int(2))
        XCTAssertEqual(row["system_audio"], .bool(true))
        XCTAssertEqual(row["mic_on"], .bool(true))
        XCTAssertEqual(row["jitter_target"], .int(3))
        XCTAssertEqual(row["output_device"], .string("MacBook Pro Speakers"))
        XCTAssertEqual(row["window_ms"], .int(5000))
    }

    func testUnknownOutputDeviceIsAbsentRatherThanNamed() {
        let row = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context(outputDevice: nil))
        XCTAssertNil(row["output_device"])
    }

    /// Zero would read as "nothing was dropped", the opposite of "nobody
    /// was counting".
    func testUntrackedPlaybackQueueOmitsItsCountersRatherThanReportingZero() {
        let untracked = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context(queueTracked: false))
        XCTAssertNil(untracked["overruns"])
        XCTAssertNil(untracked["underruns"])

        let tracked = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context(queueTracked: true))
        XCTAssertEqual(tracked["overruns"], .int(0))
        XCTAssertEqual(tracked["underruns"], .int(0))
    }

    // MARK: - When there is a row at all

    func testAnyLiveAudioIsWorthARow() {
        XCTAssertTrue(VoiceStats.shouldRecordSummary(context: context(voiceStreams: 1)))
        XCTAssertTrue(
            VoiceStats.shouldRecordSummary(context: context(voiceStreams: 0, systemAudio: true)))
        XCTAssertTrue(
            VoiceStats.shouldRecordSummary(context: context(voiceStreams: 0, micOn: true)))
    }

    /// Suppressing a window whose counters didn't move hides a steady-state
    /// fault. Suppressing a window with no audio hides nothing — lifecycle
    /// events already say whether audio should have been running.
    func testNoAudioMeansNoRow() {
        XCTAssertFalse(
            VoiceStats.shouldRecordSummary(
                context: context(voiceStreams: 0, systemAudio: false, micOn: false)))
    }

    /// "The other side can't hear me" and "I can't hear the other side" are
    /// the same bundle without this row.
    func testLiveMicWithNoInboundStreamsStillRecords() {
        let live = context(voiceStreams: 0, micOn: true)
        XCTAssertTrue(VoiceStats.shouldRecordSummary(context: live))
        let row = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: live)
        XCTAssertEqual(row["voice_streams"], .int(0))
        XCTAssertEqual(row["mic_on"], .bool(true))
    }
}
