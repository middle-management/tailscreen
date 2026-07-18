import XCTest

@testable import TailscreenAudio

/// Smoke tests proving the TailscreenAudio module (the Opus codec wrapper) is
/// *usable* on Linux — encode/decode actually runs against libopus, not merely
/// compiles. Deliberately shallow: the fuller `[Float]`-contract coverage lives
/// in the main repo's `Tests/TailscreenTests/OpusAudioCodecTests`, which
/// compiles these same sources as part of the Tailscreen target.
final class AudioSmokeTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()
        // One 20 ms frame (960 samples) of a 440 Hz sine at 48 kHz mono.
        let frame = (0..<OpusVoiceEncoder.frameSamples).map { i in
            Float(0.5 * sin(2 * .pi * 440 * Double(i) / 48_000))
        }
        let packet = try XCTUnwrap(try encoder.encode(pcm: frame))
        XCTAssertGreaterThan(packet.count, 0)
        let decoded = try decoder.decode(au: packet)
        XCTAssertEqual(decoded.count, OpusVoiceEncoder.frameSamples)
    }

    func testWrongFrameSizeThrows() throws {
        let encoder = try OpusVoiceEncoder(application: .audio)
        XCTAssertThrowsError(try encoder.encode(pcm: [Float](repeating: 0, count: 1024)))
    }

    func testPCMConversionClampsOutOfRange() {
        XCTAssertEqual(OpusPCM.floatToInt16([6.0, -6.0]), [32767, -32767])
    }
}
