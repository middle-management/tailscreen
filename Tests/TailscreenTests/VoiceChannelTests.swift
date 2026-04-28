import XCTest
@testable import Tailscreen

final class VoiceChannelTests: XCTestCase {
    func testProcessOutboundFrameEmitsRTPPacket() throws {
        var sent: [Data] = []
        let channel = try VoiceChannel(
            localSSRC: 0xAA,
            onSend: { sent.append($0) }
        )

        channel.isMuted = false

        // 1024 samples at 48 kHz = one AU.
        let pcm = (0..<1024).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
        channel.processOutboundFrame(pcm)
        channel.flushForTesting()

        XCTAssertEqual(sent.count, 1, "one frame should produce one RTP packet")

        // Packet PT must be 98 and SSRC must match.
        let parsed = AudioRTPDepacketizer().unpack(sent[0])
        XCTAssertEqual(parsed?.payloadType, 98)
        XCTAssertEqual(parsed?.ssrc, 0xAA)
        XCTAssertGreaterThan(parsed?.au.count ?? 0, 0)
    }

    func testInboundDecodesPerSSRC() throws {
        var sent: [Data] = []
        let speaker = try VoiceChannel(
            localSSRC: 0xBB,
            onSend: { sent.append($0) }
        )
        speaker.isMuted = false
        let pcm = (0..<1024).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
        // Need a few frames because AAC encoder primer drops first AU.
        for _ in 0..<5 { speaker.processOutboundFrame(pcm) }
        speaker.flushForTesting()
        XCTAssertGreaterThanOrEqual(sent.count, 3)

        let listener = try VoiceChannel(
            localSSRC: 0xCC,
            onSend: { _ in }
        )
        var receivedAnyPCM = false
        listener.onMixedPCM = { samples in
            if !samples.isEmpty { receivedAnyPCM = true }
        }
        for packet in sent {
            listener.receive(packet)
        }
        listener.flushForTesting()
        XCTAssertTrue(receivedAnyPCM, "listener should decode and surface PCM")
    }

    func testMutedDoesNotSend() throws {
        var sent: [Data] = []
        let channel = try VoiceChannel(
            localSSRC: 1,
            onSend: { sent.append($0) }
        )
        channel.isMuted = true

        let pcm = [Float](repeating: 0, count: 1024)
        channel.processOutboundFrame(pcm)
        channel.flushForTesting()

        XCTAssertEqual(sent.count, 0)
    }
}
