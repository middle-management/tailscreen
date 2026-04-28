import XCTest
import AVFoundation
@testable import Tailscreen

final class AACCodecTests: XCTestCase {
    func testEncodeDecodeRoundtripWaveformShape() throws {
        let encoder = try AACEncoder()
        let decoder = try AACDecoder()

        // 100 ms of 440 Hz sine at 48 kHz mono Float32 = ~5 frames of 1024.
        let sampleRate: Double = 48_000
        let frequency: Double = 440
        let frameCount = 1024
        let totalFrames = frameCount * 5
        var samples = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames {
            samples[i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
        }

        // Feed in 1024-sample blocks; collect AAC AU bytes.
        var encoded: [Data] = []
        for blockIdx in 0..<5 {
            let block = Array(samples[blockIdx * frameCount ..< (blockIdx + 1) * frameCount])
            if let au = try encoder.encode(pcm: block) {
                encoded.append(au)
            }
        }
        XCTAssertGreaterThanOrEqual(encoded.count, 3, "encoder should emit something for 5 frames")

        // Decode all AUs back to PCM and check RMS energy is non-trivial.
        var decoded: [Float] = []
        for au in encoded {
            let pcm = try decoder.decode(au: au)
            decoded.append(contentsOf: pcm)
        }
        XCTAssertGreaterThan(decoded.count, 0, "decoder should produce samples")

        let rms = sqrt(decoded.reduce(0) { $0 + $1 * $1 } / Float(decoded.count))
        XCTAssertGreaterThan(rms, 0.1, "decoded sine should have meaningful RMS, got \(rms)")
        XCTAssertLessThan(rms, 1.5, "decoded sine should not be wildly clipped, got \(rms)")
    }
}
