import XCTest

@testable import TailscreenAudio

/// The capture-side audio arithmetic, which is where every microphone bug in
/// this shape hides. None of these failures throws: a wrong ratio is a
/// chipmunk, a dropped remainder is a pitch that climbs over a call, a
/// boundary discontinuity is a click 50 times a second, and a leaky mute is a
/// privacy failure that looks exactly like working software.
final class MicrophoneCaptureTests: XCTestCase {

    // MARK: Downmix

    func testStereoIsAveragedNotChannelZero() {
        let converter = CapturePCMConverter()
        // A headset that presents a mono mic as stereo may put the signal on
        // EITHER channel. Taking channel 0 gives silence half the time, on
        // hardware nobody tested against.
        let leftOnly = converter.convert(
            [1, 0, 1, 0], from: AudioInputFormat(sampleRate: 48_000, channelCount: 2))
        let rightOnly = converter.convert(
            [0, 1, 0, 1], from: AudioInputFormat(sampleRate: 48_000, channelCount: 2))
        XCTAssertEqual(leftOnly, [0.5, 0.5])
        XCTAssertEqual(rightOnly, [0.5, 0.5])
    }

    func testMonoPassesThroughAt48k() {
        let converter = CapturePCMConverter()
        let input: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(converter.convert(input, from: .wire), input)
    }

    func testAPartialTrailingFrameIsIgnoredRatherThanMisread() {
        let converter = CapturePCMConverter()
        // Five values on a stereo stream is two whole frames plus a stray.
        // Reading the stray as a frame would pair it with whatever comes next.
        let out = converter.convert(
            [1, 1, 1, 1, 1], from: AudioInputFormat(sampleRate: 48_000, channelCount: 2))
        XCTAssertEqual(out.count, 2)
    }

    // MARK: Resampling

    func testDownsamplingProducesRoughlyTheRightCount() {
        let converter = CapturePCMConverter()
        // One second of 96 kHz should land near 48 000 samples.
        let input = [Float](repeating: 0.25, count: 96_000)
        let out = converter.convert(
            input, from: AudioInputFormat(sampleRate: 96_000, channelCount: 1))
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 4)
    }

    func testUpsamplingFrom44100ProducesRoughlyTheRightCount() {
        let converter = CapturePCMConverter()
        let input = [Float](repeating: 0.25, count: 44_100)
        let out = converter.convert(
            input, from: AudioInputFormat(sampleRate: 44_100, channelCount: 1))
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 4)
    }

    func testBufferBoundariesStayContinuous() {
        let converter = CapturePCMConverter()
        let format = AudioInputFormat(sampleRate: 44_100, channelCount: 1)
        // A constant signal must stay constant across a boundary. If the
        // carried neighbour were dropped, the first output of each buffer
        // would interpolate from silence — a click ~50 times a second, which
        // is audible and is exactly what this state exists to prevent.
        _ = converter.convert([Float](repeating: 0.5, count: 441), from: format)
        let second = converter.convert([Float](repeating: 0.5, count: 441), from: format)
        for sample in second {
            XCTAssertEqual(sample, 0.5, accuracy: 0.001)
        }
    }

    func testTheFractionalRemainderIsCarriedAcrossBuffers() {
        let converter = CapturePCMConverter()
        let format = AudioInputFormat(sampleRate: 44_100, channelCount: 1)
        // Twenty 10 ms buffers at 44.1 kHz is 200 ms of audio, which is 9 600
        // samples at 48 kHz. Re-aligning to a sample boundary every buffer
        // instead of carrying the phase would lose a fraction each time and
        // drift — inaudible per buffer, a rising pitch over a call.
        var total = 0
        for _ in 0..<20 {
            total += converter.convert([Float](repeating: 0.1, count: 441), from: format).count
        }
        XCTAssertEqual(Double(total), 9_600, accuracy: 3)
    }

    func testAFormatChangeResetsRatherThanResamplingAgainstAStaleRate() {
        let converter = CapturePCMConverter()
        _ = converter.convert(
            [Float](repeating: 0.9, count: 441),
            from: AudioInputFormat(sampleRate: 44_100, channelCount: 1))
        // The device was reconfigured under the stream. The new buffer must be
        // measured against the NEW rate — which is the whole reason the format
        // rides every callback instead of being read once at start.
        let out = converter.convert(
            [Float](repeating: 0.0, count: 960),
            from: AudioInputFormat(sampleRate: 48_000, channelCount: 1))
        XCTAssertEqual(out.count, 960, "48 kHz mono is a pass-through, whatever came before")
    }

    func testDegenerateFormatsProduceNothingRatherThanDividingByZero() {
        let converter = CapturePCMConverter()
        XCTAssertTrue(
            converter.convert([1, 2, 3], from: AudioInputFormat(sampleRate: 0, channelCount: 1))
                .isEmpty)
        XCTAssertTrue(
            converter.convert([1, 2, 3], from: AudioInputFormat(sampleRate: 48_000, channelCount: 0))
                .isEmpty)
        XCTAssertTrue(converter.convert([], from: .wire).isEmpty)
    }

    // MARK: Framing

    func testFramerEmitsWholeFramesAndCarriesTheRemainder() {
        var framer = PCMFramer(frameSamples: 960)
        XCTAssertTrue(framer.push([Float](repeating: 0, count: 500)).isEmpty)
        XCTAssertEqual(framer.pendingSamples, 500)
        let frames = framer.push([Float](repeating: 0, count: 500))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 960)
        // 40 left over — carried, not dropped. Dropping is inaudible per
        // buffer and a rising pitch over a call.
        XCTAssertEqual(framer.pendingSamples, 40)
    }

    func testFramerDrainsMultipleFramesFromOneBuffer() {
        var framer = PCMFramer(frameSamples: 960)
        let frames = framer.push([Float](repeating: 0, count: 960 * 3 + 7))
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(framer.pendingSamples, 7)
    }

    func testFramerPreservesOrder() {
        var framer = PCMFramer(frameSamples: 2)
        let frames = framer.push([1, 2, 3, 4, 5, 6])
        XCTAssertEqual(frames, [[1, 2], [3, 4], [5, 6]])
    }

    func testFramerResetDropsThePartialFrame() {
        var framer = PCMFramer(frameSamples: 960)
        _ = framer.push([Float](repeating: 0.5, count: 100))
        framer.reset()
        XCTAssertEqual(framer.pendingSamples, 0)
    }

    // MARK: Mute

    func testMutedAudioNeverReachesTheEncoder() throws {
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        var emitted = 0
        pipeline.onAccessUnit = { _ in emitted += 1 }

        pipeline.isMuted = true
        // Well over a frame's worth of loud audio.
        for _ in 0..<10 {
            pipeline.ingest([Float](repeating: 0.8, count: 960), format: .wire)
        }
        XCTAssertEqual(emitted, 0, "muting drops at the source; nothing downstream sees a sample")
    }

    func testUnmutingDoesNotEmitAudioRecordedWhileMuted() throws {
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        var emitted = 0
        pipeline.onAccessUnit = { _ in emitted += 1 }

        // Half a frame of live audio, then mute mid-frame.
        pipeline.ingest([Float](repeating: 0.8, count: 480), format: .wire)
        pipeline.isMuted = true
        pipeline.ingest([Float](repeating: 0.8, count: 480), format: .wire)
        XCTAssertEqual(emitted, 0)

        // Unmute and supply exactly half a frame. If the pre-mute remainder
        // had survived, this would complete a frame and ship audio captured
        // around the moment the user pressed mute.
        pipeline.isMuted = false
        pipeline.ingest([Float](repeating: 0.8, count: 480), format: .wire)
        XCTAssertEqual(emitted, 0, "the partial frame is dropped at mute, not held")
    }

    func testUnmutedAudioIsEncoded() throws {
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        var packets: [Data] = []
        pipeline.onAccessUnit = { packets.append($0) }

        // A real signal rather than silence, so a codec that elides digital
        // silence cannot make this pass vacuously.
        var tone = [Float](repeating: 0, count: 960 * 4)
        for i in tone.indices {
            tone[i] = sin(Float(i) * 0.05) * 0.5
        }
        pipeline.ingest(tone, format: .wire)
        XCTAssertEqual(packets.count, 4, "four 20 ms frames in, four packets out")
        XCTAssertTrue(packets.allSatisfy { !$0.isEmpty })
    }

    func testResampledInputStillFramesToExactlyTwentyMilliseconds() throws {
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        var packets = 0
        pipeline.onAccessUnit = { _ in packets += 1 }
        // One second of 44.1 kHz stereo — the format a laptop actually hands
        // over — must come out as ~50 packets, not 44 or 48.
        let format = AudioInputFormat(sampleRate: 44_100, channelCount: 2)
        var tone = [Float](repeating: 0, count: 44_100 * 2)
        for i in tone.indices { tone[i] = sin(Float(i) * 0.01) * 0.4 }
        pipeline.ingest(tone, format: format)
        XCTAssertEqual(Double(packets), 50, accuracy: 1)
    }
}
