import XCTest

@testable import ALSAKit

/// Proves the ALSA playback wrapper actually *runs* — opens a PCM device,
/// configures it, and writes frames — on whatever Linux CI builds it. Every
/// test opens the `"null"` device, ALSA's always-present discard PCM: it needs
/// no sound hardware and no mixer server, so these run headless (the real
/// `"default"` device is deliberately never opened — CI has no audio output).
final class PCMPlayerTests: XCTestCase {
    /// One 20 ms frame of a 440 Hz sine at 48 kHz, mono, as Float32 in [-1, 1]
    /// — the shape `OpusVoiceDecoder` hands the viewer.
    private func sineFrame(hz: Double = 440, amplitude: Double = 0.5) -> [Float] {
        let n = 960
        return (0..<n).map { i in
            let t = Double(i) / 48_000
            return Float(amplitude * sin(2 * .pi * hz * t))
        }
    }

    func testWriteOneFrameToNullDevice() throws {
        let player = try ALSA.PCMPlayer(device: "null")
        let written = try player.write(sineFrame())
        // The null PCM accepts (and discards) the whole 960-sample mono frame.
        XCTAssertEqual(written, 960)
    }

    func testWriteMultipleFramesInARow() throws {
        let player = try ALSA.PCMPlayer(device: "null")
        // Stream a short run of frames to exercise repeated writes, not just a
        // single buffer — the viewer feeds one 20 ms frame at a time.
        for hz in stride(from: 220.0, through: 880.0, by: 110.0) {
            let written = try player.write(sineFrame(hz: hz))
            XCTAssertGreaterThan(written, 0)
        }
        // Draining an idle/finished stream must not throw.
        try player.drain()
    }

    func testWriteSilenceToNullDevice() throws {
        let player = try ALSA.PCMPlayer(device: "null")
        let silence = [Float](repeating: 0, count: 960)
        XCTAssertEqual(try player.write(silence), 960)
    }

    func testEmptyBufferIsANoOp() throws {
        let player = try ALSA.PCMPlayer(device: "null")
        XCTAssertEqual(try player.write([]), 0)
    }
}
