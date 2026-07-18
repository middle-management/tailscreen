import XCTest

@testable import OpusKit

/// Proves the libopus wrapper actually *runs* — encode → decode round trips —
/// on whatever platform CI builds it (Linux today; macOS/Windows when those
/// jobs exist). Opus is lossy, so these assert structural correctness and
/// rough signal preservation, never byte-exact output.
final class OpusRoundTripTests: XCTestCase {
    /// One 20 ms frame of a 440 Hz sine at 48 kHz, mono, as Int16 PCM.
    private func sineFrame(hz: Double = 440, amplitude: Double = 0.5) -> [Int16] {
        let n = Int(Opus.FrameSize.ms20.rawValue)
        return (0..<n).map { i in
            let t = Double(i) / Double(Opus.sampleRate)
            return Int16(amplitude * 32767 * sin(2 * .pi * hz * t))
        }
    }

    func testEncodeThenDecodeRoundTrip() throws {
        let encoder = try Opus.Encoder()
        try encoder.setBitrate(24_000)
        let decoder = try Opus.Decoder()

        let input = sineFrame()
        let packet = try encoder.encode(input)
        // A real Opus packet: non-empty and far smaller than the raw PCM
        // (960 samples × 2 bytes = 1920 raw).
        XCTAssertGreaterThan(packet.count, 0)
        XCTAssertLessThan(packet.count, input.count * 2)

        let output = try decoder.decode(packet)
        // Opus adds algorithmic delay, but a 20 ms frame decodes to 20 ms.
        XCTAssertEqual(output.count, input.count)
        // Lossy, so not byte-exact — but a loud sine must decode to a
        // non-silent frame with comparable energy (within a wide band).
        let inEnergy = input.reduce(0.0) { $0 + Double($1) * Double($1) }
        let outEnergy = output.reduce(0.0) { $0 + Double($1) * Double($1) }
        XCTAssertGreaterThan(outEnergy, inEnergy * 0.25, "decoded frame lost too much energy")
    }

    func testMultipleFramesStreamThrough() throws {
        let encoder = try Opus.Encoder()
        let decoder = try Opus.Decoder()
        // Encoder/decoder are stateful; run a short stream to exercise
        // inter-frame prediction, not just a single frame.
        for hz in stride(from: 220.0, through: 880.0, by: 110.0) {
            let packet = try encoder.encode(sineFrame(hz: hz))
            let output = try decoder.decode(packet)
            XCTAssertEqual(output.count, Int(Opus.FrameSize.ms20.rawValue))
        }
    }

    func testPacketLossConcealmentProducesAFrame() throws {
        let encoder = try Opus.Encoder()
        let decoder = try Opus.Decoder()
        // Prime the decoder so PLC has recent history to extrapolate from.
        _ = try decoder.decode(try encoder.encode(sineFrame()))
        // A nil packet (lost) must still yield a full concealment frame,
        // never throw — this is what the jitter buffer leans on across gaps.
        let concealed = try decoder.decode(nil, frameSize: .ms20)
        XCTAssertEqual(concealed.count, Int(Opus.FrameSize.ms20.rawValue))
    }

    func testWrongFrameSizeRejected() throws {
        let encoder = try Opus.Encoder()
        // 500 samples is not a valid Opus frame — encode must reject it
        // rather than emit a corrupt packet.
        XCTAssertThrowsError(try encoder.encode([Int16](repeating: 0, count: 500)))
    }
}
