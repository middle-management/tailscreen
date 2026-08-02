import XCTest

@testable import ALSAKit

/// Proves the ALSA **capture** wrapper actually runs — opens a PCM device,
/// negotiates a format with it, reads frames, and tears down — on whatever
/// Linux CI builds it.
///
/// Every live test opens the `"null"` device. It is ALSA's always-present
/// discard PCM, and — unlike a loopback or a file plugin — it works in *both*
/// directions: `SND_PCM_STREAM_CAPTURE` on `null` opens, accepts any rate and
/// channel count, starts, and returns full buffers of digital silence
/// immediately, with no hardware, no mixer server and no real-time pacing.
/// That is enough to exercise open / hw-param negotiation / the read path /
/// close for real; it is deliberately never `"default"`, which CI has no input
/// device for.
///
/// What `null` cannot do is produce a *signal*, so nothing here asserts on
/// sample values — a silence assertion would pass against a `read` that
/// returned its own zero-filled scratch buffer without ever calling libasound,
/// which is the definition of a test that cannot fail. The channel fold's
/// arithmetic is therefore pinned separately, on `downmixToMono` directly.
final class PCMRecorderTests: XCTestCase {
    // MARK: - Live capture against the null device

    func testNegotiatesRequestedFormatOnNullDevice() throws {
        let recorder = try ALSA.PCMRecorder(preferredSampleRate: 48_000, preferredChannels: 1, device: "null")
        XCTAssertEqual(recorder.format, ALSA.PCMRecorder.Format(sampleRate: 48_000, channels: 1))
        // The period is asked for in *time* (20 ms — one Opus frame), so the
        // invariant is a fiftieth of whatever rate was negotiated, not a
        // hardcoded 960 that a different alsa-lib could legitimately miss.
        XCTAssertEqual(recorder.periodFrames, Int(recorder.format.sampleRate) / 50)
    }

    func testReadReturnsOneMonoSamplePerFrame() throws {
        let recorder = try ALSA.PCMRecorder(device: "null")
        let samples = try recorder.read(frames: 960)
        XCTAssertEqual(samples.count, 960)
    }

    /// The one live assertion the channel fold gets: `null` will hand back a
    /// genuinely 2-channel stream, so a 960-frame read must still come back as
    /// 960 mono samples. A `read` that forgot to fold — or that confused frames
    /// with samples in its buffer sizing — returns 1920 here.
    func testStereoDeviceIsFoldedToMonoOnTheWayOut() throws {
        let recorder = try ALSA.PCMRecorder(preferredSampleRate: 44_100, preferredChannels: 2, device: "null")
        XCTAssertEqual(recorder.format, ALSA.PCMRecorder.Format(sampleRate: 44_100, channels: 2))
        let samples = try recorder.read(frames: 960)
        XCTAssertEqual(samples.count, 960)
    }

    func testMultipleReadsInARowThenStopAndResume() throws {
        let recorder = try ALSA.PCMRecorder(device: "null")
        for _ in 0..<5 {
            XCTAssertEqual(try recorder.read(frames: recorder.periodFrames).count, recorder.periodFrames)
        }
        // `stop()` drops the device's buffered audio and re-prepares, so the
        // stream is reusable — a drop without the prepare leaves the handle in
        // SETUP and every later read fails with -EBADFD.
        try recorder.stop()
        XCTAssertEqual(try recorder.read(frames: 480).count, 480)
    }

    /// A non-positive read is a no-op, and the stream survives it.
    ///
    /// The zero case is only half of this. The half that bites is a *negative*
    /// count — a caller computing `wanted - alreadyHave` and going one past —
    /// which without the guard reaches `[Float](repeating:count:)` with a
    /// negative capacity and traps the whole process before libasound is ever
    /// asked anything.
    func testNonPositiveReadIsANoOp() throws {
        let recorder = try ALSA.PCMRecorder(device: "null")
        XCTAssertEqual(try recorder.read(frames: 0).count, 0)
        XCTAssertEqual(try recorder.read(frames: -1).count, 0)
        XCTAssertEqual(try recorder.read(frames: 480).count, 480)
    }

    /// A device that isn't there must throw, not trap and not open a silent
    /// stream that records nothing.
    func testUnknownDeviceThrowsALSAError() {
        XCTAssertThrowsError(try ALSA.PCMRecorder(device: "tailscreen-no-such-pcm")) { error in
            guard let alsaError = error as? ALSA.Error else {
                return XCTFail("expected ALSA.Error, got \(error)")
            }
            XCTAssertLessThan(alsaError.code, 0)
            XCTAssertFalse(alsaError.message.isEmpty)
        }
    }

    // MARK: - The channel fold (pure arithmetic; no device involved)

    func testMonoDownmixIsIdentity() {
        let input: [Float] = [0.25, -0.5, 1, -1]
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono(input, channels: 1), input)
    }

    func testStereoDownmixAverages() {
        // L/R pairs: (1, -1) cancels, (0.5, 0.5) holds, (0, 1) halves.
        let input: [Float] = [1, -1, 0.5, 0.5, 0, 1]
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono(input, channels: 2), [0, 0.5, 0.5])
    }

    /// Averaging, not summing. Summing is the fold everyone writes first, and
    /// it is inaudible on a test tone and full-scale distortion on a real
    /// correlated stereo mic — nothing in the pipeline reports it.
    func testCorrelatedChannelsDoNotExceedFullScale() {
        let bothChannelsAtFullScale: [Float] = [1, 1, -1, -1]
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono(bothChannelsAtFullScale, channels: 2), [1, -1])
    }

    func testMultiChannelDownmixAveragesAllChannels() {
        // One 4-channel frame; the mean of 1, 0, 0, 0 is 0.25.
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono([1, 0, 0, 0], channels: 4), [0.25])
    }

    /// A sample count that isn't a whole number of frames must lose the tail,
    /// not read past it.
    func testPartialTrailingFrameIsDropped() {
        let fiveSamplesOfStereo: [Float] = [1, 1, 0.5, 0.5, 0.25]
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono(fiveSamplesOfStereo, channels: 2), [1, 0.5])
    }

    func testZeroChannelsYieldsNothingRatherThanDividingByZero() {
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono([1, 2, 3], channels: 0), [])
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(ALSA.PCMRecorder.downmixToMono([], channels: 2), [])
    }
}
