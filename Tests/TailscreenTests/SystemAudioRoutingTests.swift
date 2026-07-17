import OpusKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// CI-able coverage of the viewer-side audio demux: the pure
/// `VoiceChannel.audioRoute` decision plus an in-process `receive` that proves
/// a real PT-99 packet fires `onSystemAudioPCM` and never `onMixedPCM`.
final class SystemAudioRoutingTests: XCTestCase {
    /// Reference box so the closures can flip a flag without a mutable capture.
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    func testVoicePayloadTypeRoutesToVoice() {
        XCTAssertEqual(VoiceChannel.audioRoute(payloadType: RTPHeader.aacPayloadType), .voice)
    }

    func testSystemAudioPayloadTypeRoutesToSystemAudio() {
        XCTAssertEqual(
            VoiceChannel.audioRoute(payloadType: RTPHeader.systemAudioPayloadType), .systemAudio)
    }

    func testVideoPayloadTypesDrop() {
        XCTAssertEqual(VoiceChannel.audioRoute(payloadType: RTPHeader.h264PayloadType), .drop)
        XCTAssertEqual(VoiceChannel.audioRoute(payloadType: RTPHeader.hevcPayloadType), .drop)
        XCTAssertEqual(VoiceChannel.audioRoute(payloadType: 200), .drop)
    }

    func testReceiveRoutesSystemAudioToSystemCallbackOnly() throws {
        let channel = try VoiceChannel(localSSRC: 5) { _ in }
        let encoder = try OpusVoiceEncoder(application: .audio)

        // A short run of encoded system-audio frames (one packet per frame).
        let packetizer = AudioRTPPacketizer(
            ssrc: RTPHeader.systemAudioSSRC, payloadType: RTPHeader.systemAudioPayloadType)
        var packets: [Data] = []
        for _ in 0..<6 {
            if let au = try encoder.encode(pcm: [Float](repeating: 0.15, count: 960)) {
                packets.append(packetizer.packetize(au: au))
            }
        }
        XCTAssertFalse(packets.isEmpty)

        let systemFired = expectation(description: "onSystemAudioPCM fires")
        systemFired.assertForOverFulfill = false
        let mixedFired = Flag()
        channel.onSystemAudioPCM = { _ in systemFired.fulfill() }
        channel.onMixedPCM = { _ in mixedFired.value = true }

        for packet in packets {
            channel.receive(packet)
        }
        channel.flushForTesting()

        wait(for: [systemFired], timeout: 2)
        XCTAssertFalse(mixedFired.value, "system audio must not reach the voice mix callback")
    }
}
