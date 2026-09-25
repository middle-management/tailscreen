import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// `VoiceStats.audioSummaryFields` and `shouldRecordSummary` — the
/// `audio.summary` row and the rule for when there is one.
///
/// The row exists because the voice counters had no way into a bundle. They
/// reached one only through a log line gated on "at most once a minute, and
/// only if a counter moved", so a call that sounded wrong while the counters
/// sat still produced nothing at all — indistinguishable from a call with no
/// voice in it, which is the same silence `transport.summary` was added to
/// break. Read `testARowIsRecordedEvenWhenNothingMoved` first: it is the
/// whole point, and an implementation that kept the old guard would satisfy
/// every other case here.
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

    /// A window in which no counter moved is still a row.
    func testARowIsRecordedEvenWhenNothingMoved() {
        let stats = VoiceStats()
        let row = stats.audioSummaryFields(since: stats, windowNs: window, context: context())
        XCTAssertEqual(row["concealed"], .int(0))
        XCTAssertEqual(row["clamped"], .int(0))
        XCTAssertEqual(row["voice_streams"], .int(1))
    }

    /// And it has exactly the keys a bad window has, which is what makes the
    /// two comparable at all.
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

    /// Counters are reported as what happened in THIS window, like the
    /// transport row beside it — a running total makes a reader subtract two
    /// rows to answer the question the row is for.
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

    /// Jitter is a gauge, not a counter: it is reported as it stands.
    func testJitterIsReportedAsItStandsAndRounded() {
        var now = VoiceStats()
        now.smoothedJitterMs = 12.34
        var previous = VoiceStats()
        previous.smoothedJitterMs = 99
        let row = now.audioSummaryFields(since: previous, windowNs: window, context: context())
        XCTAssertEqual(row["jitter_ms"], .double(12.3))
    }

    /// System-audio clipping is its own number.
    ///
    /// The two clip for different reasons and only one of them is the voice
    /// path's doing: voice alone says this stream arrived hot, both together
    /// say the host's output mixer is summing them past full scale — which is
    /// a distortion report's most likely mundane explanation and was, before
    /// this, not visible anywhere.
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

    /// The context half. Without it "concealed 0, clamped 0" is equally true
    /// of a clean call and of one distorting somewhere the voice path cannot
    /// see, so the row names what was feeding the output while it measured.
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

    /// A host that does not name its devices omits the field rather than
    /// inventing a placeholder.
    func testUnknownOutputDeviceIsAbsentRatherThanNamed() {
        let row = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: context(outputDevice: nil))
        XCTAssertNil(row["output_device"])
    }

    /// The playback queue belongs to the host's audio sink, not to the decode
    /// path, so a host without one omits both counters instead of reporting
    /// zero. Zero would read as "nothing was dropped", which is the opposite
    /// of "nobody was counting" — the exact confusion this whole event exists
    /// to remove.
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

    /// Recorded while audio is running, in any of the three ways it can be.
    func testAnyLiveAudioIsWorthARow() {
        XCTAssertTrue(VoiceStats.shouldRecordSummary(context: context(voiceStreams: 1)))
        XCTAssertTrue(
            VoiceStats.shouldRecordSummary(context: context(voiceStreams: 0, systemAudio: true)))
        XCTAssertTrue(
            VoiceStats.shouldRecordSummary(context: context(voiceStreams: 0, micOn: true)))
    }

    /// And not recorded when nothing is playing and nothing is being sent.
    ///
    /// This is a different rule from the one it replaces, and the difference
    /// is the whole design. Suppressing a window whose COUNTERS did not move
    /// hides a steady-state fault. Suppressing a window with no audio in it
    /// hides nothing: the lifecycle events already say whether audio should
    /// have been running, so an absent row reads as "there was none" rather
    /// than as "nobody looked".
    func testNoAudioMeansNoRow() {
        XCTAssertFalse(
            VoiceStats.shouldRecordSummary(
                context: context(voiceStreams: 0, systemAudio: false, micOn: false)))
    }

    /// A live microphone with nothing arriving is a row, and it is one of the
    /// rows most worth having: "the other side cannot hear me" and "I cannot
    /// hear the other side" are the same bundle without it.
    func testLiveMicWithNoInboundStreamsStillRecords() {
        let live = context(voiceStreams: 0, micOn: true)
        XCTAssertTrue(VoiceStats.shouldRecordSummary(context: live))
        let row = VoiceStats().audioSummaryFields(
            since: VoiceStats(), windowNs: window, context: live)
        XCTAssertEqual(row["voice_streams"], .int(0))
        XCTAssertEqual(row["mic_on"], .bool(true))
    }
}
