import OpusKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// App-level round-trip over the `OpusVoiceEncoder` / `OpusVoiceDecoder`
/// wrappers (the Float32↔Int16 boundary + 960-sample framing on top of
/// OpusKit). OpusKit's own package tests cover the raw libopus binding; these
/// pin the Tailscreen-facing `[Float]` contract that replaced AAC.
final class OpusAudioCodecTests: XCTestCase {
    /// One 20 ms frame (960 samples) of a 440 Hz sine at 48 kHz mono, Float32.
    private func sineFrame(hz: Double = 440, amplitude: Double = 0.5) -> [Float] {
        (0..<OpusVoiceEncoder.frameSamples).map { i in
            Float(amplitude * sin(2 * .pi * hz * Double(i) / 48_000))
        }
    }

    func testEncodeDecodeRoundtripWaveformShape() throws {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()

        // A short stream (encoder/decoder are stateful) of five 20 ms frames.
        var decoded: [Float] = []
        for _ in 0..<5 {
            let au = try XCTUnwrap(try encoder.encode(pcm: sineFrame()))
            // A real Opus packet: non-empty, far smaller than the raw PCM
            // (960 samples × 2 bytes = 1920).
            XCTAssertGreaterThan(au.count, 0)
            XCTAssertLessThan(au.count, OpusVoiceEncoder.frameSamples * 2)
            let pcm = try decoder.decode(au: au)
            XCTAssertEqual(pcm.count, OpusVoiceEncoder.frameSamples, "20 ms frame decodes to 960 samples")
            decoded.append(contentsOf: pcm)
        }

        // Lossy, so not byte-exact — but a loud sine must decode to non-silent
        // audio with meaningful, non-clipped RMS.
        let rms = sqrt(decoded.reduce(0) { $0 + $1 * $1 } / Float(decoded.count))
        XCTAssertGreaterThan(rms, 0.1, "decoded sine should have meaningful RMS, got \(rms)")
        XCTAssertLessThan(rms, 1.5, "decoded sine should not be wildly clipped, got \(rms)")
    }

    func testWrongFrameSizeThrows() throws {
        let encoder = try OpusVoiceEncoder()
        // 1024 samples (the old AAC AU size) is not a valid Opus frame — the
        // wrapper must reject it rather than emit a corrupt packet.
        XCTAssertThrowsError(try encoder.encode(pcm: [Float](repeating: 0, count: 1024)))
    }

    func testAudioApplicationModeEncodes() throws {
        // The system-audio path uses `.audio` (music) mode; prove it encodes.
        let encoder = try OpusVoiceEncoder(application: .audio)
        let au = try XCTUnwrap(try encoder.encode(pcm: sineFrame()))
        XCTAssertGreaterThan(au.count, 0)
    }

    func testPCMConversionRoundTripsWithinQuantization() {
        let input: [Float] = [0, 0.5, -0.5, 1.0, -1.0, 0.25]
        let back = OpusPCM.int16ToFloat(OpusPCM.floatToInt16(input))
        for (a, b) in zip(input, back) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 32767.0 + 1e-6)
        }
    }

    func testPCMConversionClampsOutOfRange() {
        // A stray >1.0 peak must saturate, never wrap to the opposite sign.
        let clamped = OpusPCM.floatToInt16([6.0, -6.0])
        XCTAssertEqual(clamped, [32767, -32767])
    }
}
