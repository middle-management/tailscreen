import XCTest

@testable import WASAPIKit

/// Covers the microphone path's arithmetic — the whole of what is testable off
/// Windows, and deliberately where the decisions live.
///
/// ALSAKit's `PCMPlayerTests` can open ALSA's `null` PCM and prove the real
/// wrapper runs headlessly. WASAPI has no equivalent: there is no null endpoint,
/// and more to the point no WASAPI at all on the machines that run CI. So the
/// split here is the same one `MonoPCMConverter` and `I420Converter` were pulled
/// out for — the sample-shuffling that every platform needs and no platform can
/// test sits outside `#if os(Windows)`, and the COM lifetime that genuinely
/// requires Windows is left to the `wasapi-probe` link check and a human at a
/// desk.
final class MonoDownmixTests: XCTestCase {
    // MARK: - Downmix

    func testMonoInputPassesThroughUntouched() {
        let samples: [Float] = [0.25, -0.5, 1, 0]
        XCTAssertEqual(WASAPI.downmixToMono(samples, channels: 1), samples)
    }

    func testStereoAveragesTheTwoChannels() {
        // frames: (1, 0), (0.5, -0.5), (-1, -1)
        let interleaved: [Float] = [1, 0, 0.5, -0.5, -1, -1]
        XCTAssertEqual(WASAPI.downmixToMono(interleaved, channels: 2), [0.5, 0, -1])
    }

    /// The reason this averages instead of summing: a stereo microphone whose
    /// channels carry the same signal must come out at the same level it went
    /// in, not at twice full scale.
    func testCorrelatedStereoDoesNotClip() {
        let loud: [Float] = [1, 1, -1, -1, 0.9, 0.9]
        let mono = WASAPI.downmixToMono(loud, channels: 2)
        XCTAssertEqual(mono, [1, -1, 0.9])
        for sample in mono {
            XCTAssertLessThanOrEqual(abs(sample), 1)
        }
    }

    /// Every channel contributes, unlike the macOS path's explicit channel-0
    /// pick — a WASAPI capture endpoint reports real microphone channels, not a
    /// voice-processing loopback reference.
    func testSixChannelUsesAllChannels() {
        let frame: [Float] = [0.6, 0, 0, 0, 0, 0]
        let mono = WASAPI.downmixToMono(frame, channels: 6)
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(mono[0], 0.1, accuracy: 1e-6)

        let quiet = WASAPI.downmixToMono([1, 0, 0, 0, 0, 0], channels: 6)
        // The documented cost of averaging: one live input on a six-channel
        // interface reads ~15 dB down. Pinned so the tradeoff cannot change by
        // accident.
        XCTAssertEqual(quiet[0], 1.0 / 6, accuracy: 1e-6)
    }

    /// A slice of a reused scratch buffer does not start at index 0. Indexing it
    /// as though it did reads the wrong samples — or traps.
    func testRebasedSliceIsIndexedFromItsOwnStart() {
        let backing: [Float] = [9, 9, 9, 9, 1, 1, 0.5, 0.5]
        let mono = WASAPI.downmixToMono(backing[4...], channels: 2)
        XCTAssertEqual(mono, [1, 0.5])
    }

    func testTrailingPartialFrameIsDropped() {
        // Five samples on a stereo stream: two whole frames and half of a third.
        let interleaved: [Float] = [1, 1, 0, 0, 0.5]
        XCTAssertEqual(WASAPI.downmixToMono(interleaved, channels: 2), [1, 0])
    }

    func testEmptyInputProducesNothing() {
        XCTAssertEqual(WASAPI.downmixToMono([], channels: 2), [])
        XCTAssertEqual(WASAPI.downmixToMono([], channels: 1), [])
    }

    func testShorterThanOneFrameProducesNothing() {
        XCTAssertEqual(WASAPI.downmixToMono([0.5], channels: 2), [])
    }

    /// A device claiming zero channels is nonsense, but it must not divide by
    /// zero on the way to being nonsense.
    func testNonsensicalChannelCountPassesThroughInsteadOfTrapping() {
        XCTAssertEqual(WASAPI.downmixToMono([0.5, 0.25], channels: 0), [0.5, 0.25])
        XCTAssertEqual(WASAPI.downmixToMono([0.5, 0.25], channels: -3), [0.5, 0.25])
    }

    func testLongBufferAveragesEveryFrame() {
        // 960 frames — one 20 ms Opus frame at 48 kHz, the shape this feeds.
        let frames = 960
        var interleaved: [Float] = []
        interleaved.reserveCapacity(frames * 2)
        for frame in 0..<frames {
            let value = Float(frame % 100) / 100
            interleaved.append(value)
            interleaved.append(-value)
        }
        let mono = WASAPI.downmixToMono(interleaved, channels: 2)
        XCTAssertEqual(mono.count, frames)
        // Anti-correlated channels cancel exactly.
        XCTAssertEqual(mono.max(), 0)
        XCTAssertEqual(mono.min(), 0)
    }

    // MARK: - Error mapping

    /// The shim's negative codes and the HRESULTs it passes through share one
    /// return channel, so the split between them is worth pinning.
    func testShimErrorCodesMapToTheirCases() {
        XCTAssertEqual(WASAPI.Error.from(code: -1), .unsupportedFormat)
        XCTAssertEqual(WASAPI.Error.from(code: -2), .invalidArgument)
        XCTAssertEqual(WASAPI.Error.from(code: -3), .timedOut)
        XCTAssertEqual(WASAPI.Error.from(code: -4), .bufferTooSmall)
    }

    /// The one HRESULT a user can act on. If this stops being recognised, a
    /// blocked microphone reports a hex code instead of the setting to change.
    func testMicrophonePrivacyRefusalIsNamed() {
        XCTAssertEqual(WASAPI.Error.from(code: Int32(bitPattern: 0x8007_0005)), .accessDenied)
        XCTAssertTrue(WASAPI.Error.accessDenied.description.contains("microphone"))
    }

    func testUnknownHResultKeepsItsValue() {
        let invalidated = Int32(bitPattern: 0x8889_0004)  // AUDCLNT_E_DEVICE_INVALIDATED
        XCTAssertEqual(WASAPI.Error.from(code: invalidated), .hresult(invalidated))
        XCTAssertTrue(WASAPI.Error.from(code: invalidated).description.contains("88890004"))
    }

    // MARK: - Types

    func testChunkEmptinessTracksItsSamples() {
        XCTAssertTrue(WASAPI.Chunk(mono: [], discontinuity: false).isEmpty)
        XCTAssertFalse(WASAPI.Chunk(mono: [0], discontinuity: false).isEmpty)
        // An empty chunk still carries a glitch flag: nothing arrived, but the
        // gap before the nothing is still real.
        XCTAssertTrue(WASAPI.Chunk(mono: [], discontinuity: true).discontinuity)
    }

    /// Off Windows every entry point must fail rather than silently succeed and
    /// record nothing.
    func testRecorderRefusesToOpenOffWindows() throws {
        #if os(Windows)
        throw XCTSkip("Windows has a real endpoint; opening it is not this test's business")
        #else
        XCTAssertThrowsError(try WASAPI.Recorder()) { error in
            XCTAssertEqual(error as? WASAPI.Error, .unsupportedPlatform)
        }
        #endif
    }
}
