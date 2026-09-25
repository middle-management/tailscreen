import XCTest

@testable import TailscreenViewer

/// The CPU audio conversion every non-48 kHz / non-mono device output goes
/// through. Pure arithmetic, verified here rather than by listening to a
/// Windows machine.
final class MonoPCMConverterTests: XCTestCase {
    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0) }
    }

    // MARK: - The common path

    /// "No resampling" must mean no arithmetic at all, not arithmetic that
    /// happens to round-trip.
    func testMonoAtNativeRateIsBitExact() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 48_000, channelCount: 1))
        let input: [Float] = [-1, -0.5, 0, 0.25, 1]
        XCTAssertEqual(converter.convert(input), input)
    }

    func testStereoDuplicatesIntoBothChannels() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 48_000, channelCount: 2))
        XCTAssertEqual(converter.convert([0.5, -0.25]), [0.5, 0.5, -0.25, -0.25])
    }

    /// Duplicating into all six would drive the LFE and surrounds with
    /// full-range speech; voice belongs in front left/right only.
    func testMultichannelLeavesNonFrontChannelsSilent() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 48_000, channelCount: 6))
        XCTAssertEqual(converter.convert([0.75]), [0.75, 0.75, 0, 0, 0, 0])
    }

    // MARK: - Resampling

    func testDownsampleHalvesTheFrameCount() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 24_000, channelCount: 1))
        let out = converter.convert(ramp(100))
        // ~50 frames, allowing the one-sample lookahead at the buffer edge.
        XCTAssertEqual(Double(out.count), 50, accuracy: 1)
    }

    func testUpsampleDoublesTheFrameCount() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 96_000, channelCount: 1))
        let out = converter.convert(ramp(100))
        XCTAssertEqual(Double(out.count), 200, accuracy: 2)
    }

    /// Count must not drift over successive buffers — a half-sample lost per
    /// call is 25 samples a second.
    func testFortyFourOneKeepsRateOverManyBuffers() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 44_100, channelCount: 2))
        var frames = 0
        for _ in 0..<50 {
            frames += converter.convert([Float](repeating: 0.1, count: 960)).count / 2
        }
        // 50 × 20 ms = 1 s of audio ⇒ 44,100 frames, ± the lookahead.
        XCTAssertEqual(Double(frames), 44_100, accuracy: 5)
    }

    func testConstantSignalSurvivesResampling() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 44_100, channelCount: 1))
        _ = converter.convert([Float](repeating: 0.5, count: 960))  // prime `previous`
        let out = converter.convert([Float](repeating: 0.5, count: 960))
        XCTAssertFalse(out.isEmpty)
        for sample in out {
            XCTAssertEqual(sample, 0.5, accuracy: 1e-6)
        }
    }

    /// If `previous` were dropped, the second buffer's first output would
    /// interpolate from silence and dip (the click test).
    func testBufferBoundaryDoesNotDiscontinue() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 44_100, channelCount: 1))
        let first = converter.convert(ramp(64))
        let second = converter.convert((64..<128).map { Float($0) })
        let joined = first + second
        XCTAssertGreaterThan(joined.count, 100)
        // Skip the leading sample: the stream starts against an initial
        // `previous` of 0, so the very first output is a legitimate ramp-in.
        for (a, b) in zip(joined.dropFirst(), joined.dropFirst(2)) {
            XCTAssertLessThan(a, b, "ramp must stay monotonic across the join")
        }
    }

    func testResetClearsCarriedState() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 44_100, channelCount: 1))
        _ = converter.convert([Float](repeating: 1, count: 960))
        converter.reset()
        let out = converter.convert([Float](repeating: 0, count: 960))
        for sample in out {
            XCTAssertEqual(sample, 0, accuracy: 1e-6)
        }
    }

    // MARK: - Degenerate input

    func testEmptyInputProducesNothing() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 44_100, channelCount: 2))
        XCTAssertTrue(converter.convert([]).isEmpty)
    }

    /// May legitimately emit nothing, but must advance state rather than
    /// trapping or losing the sample.
    func testSingleSampleBufferIsSafe() {
        let converter = MonoPCMConverter(
            destination: AudioOutputFormat(sampleRate: 44_100, channelCount: 1))
        XCTAssertNoThrow(_ = converter.convert([0.3]))
        let out = converter.convert([Float](repeating: 0.3, count: 480))
        XCTAssertFalse(out.isEmpty)
        for sample in out {
            XCTAssertEqual(sample, 0.3, accuracy: 1e-6)
        }
    }

    func testDegenerateFormatIsClamped() {
        let format = AudioOutputFormat(sampleRate: 0, channelCount: 0)
        XCTAssertEqual(format.sampleRate, 1)
        XCTAssertEqual(format.channelCount, 1)
    }

    /// A partial frame handed to a device desynchronises every channel after it.
    func testOutputIsAlwaysWholeFrames() {
        for channels in 1...6 {
            let converter = MonoPCMConverter(
                destination: AudioOutputFormat(sampleRate: 44_100, channelCount: channels))
            for _ in 0..<10 {
                let out = converter.convert([Float](repeating: 0.2, count: 960))
                XCTAssertEqual(out.count % channels, 0, "\(channels)ch produced a partial frame")
            }
        }
    }
}
