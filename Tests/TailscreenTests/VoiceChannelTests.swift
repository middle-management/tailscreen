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

    /// Encode `count` sine frames on a throwaway speaker channel and return
    /// the RTP packets it emitted (the encoder primer usually eats one).
    private func encodedPackets(count: Int, ssrc: UInt32) throws -> [Data] {
        var sent: [Data] = []
        let speaker = try VoiceChannel(
            localSSRC: ssrc,
            onSend: { sent.append($0) }
        )
        speaker.isMuted = false
        let pcm = (0..<1024).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
        for _ in 0..<count { speaker.processOutboundFrame(pcm) }
        speaker.flushForTesting()
        return sent
    }

    /// End-to-end resilience: packetize → seeded loss/reorder/dup via
    /// `LossyChannel` → `receive`. Concealment must fill the gaps and the
    /// pipeline must keep flowing (never wedge).
    func testLossyChannelConcealsAndKeepsFlowing() throws {
        let sent = try encodedPackets(count: 100, ssrc: 0x11)
        // Skip-if-no-output guard, mirroring ScreenShareSyntheticFramesTests'
        // VideoToolbox policy, in case a virtualized runner lacks the AAC
        // converter.
        try XCTSkipIf(sent.count < 50, "AAC encoder produced no usable output on this host")

        var impaired = LossyChannel(seed: 7, lossRate: 0.1, dupRate: 0.05, reorderWindow: 3)
        let received = impaired.transmit(sent)

        let listener = try VoiceChannel(localSSRC: 0x22, onSend: { _ in })
        var totalSamples = 0
        listener.onMixedPCM = { totalSamples += $0.count }
        for packet in received { listener.receive(packet) }
        listener.flushForTesting()

        let stats = listener.currentStats
        XCTAssertGreaterThan(stats.concealedFrames, 0, "10% seeded loss must trigger concealment")
        XCTAssertLessThanOrEqual(
            stats.discontinuities, 5, "small gaps must be concealed, not resynced")
        // Concealment fills the gaps, so total output should approximate the
        // sent duration (decoder priming may eat a frame; late reordered
        // packets are dropped as stale after their gap was concealed).
        XCTAssertGreaterThanOrEqual(
            totalSamples, sent.count * 1024 * 7 / 10, "audio flow wedged under impairment")
    }

    /// A decoder-init failure record whose cooldown has elapsed must not
    /// block the SSRC, and a successful decode must clear the record.
    func testFailureRecordClearsAfterSuccessfulDecode() throws {
        let sent = try encodedPackets(count: 5, ssrc: 0xBB)
        try XCTSkipIf(sent.count < 3, "AAC encoder produced no usable output on this host")

        let listener = try VoiceChannel(localSSRC: 0xCC, onSend: { _ in })
        // Cooldown long elapsed: machine uptime is comfortably past 5 s by
        // the time xctest runs.
        listener.injectDecoderFailureForTesting(
            ssrc: 0xBB,
            record: VoiceChannel.DecoderFailureRecord(consecutiveInitFailures: 1, lastFailureNs: 1)
        )
        var receivedAnyPCM = false
        listener.onMixedPCM = { samples in
            if !samples.isEmpty { receivedAnyPCM = true }
        }
        for packet in sent { listener.receive(packet) }
        listener.flushForTesting()

        XCTAssertTrue(receivedAnyPCM, "an elapsed cooldown must allow the retry")
        XCTAssertNil(
            listener.decoderFailuresForTesting[0xBB],
            "a successful decode must clear the failure record")
    }

    /// Packets from an SSRC inside its failure cooldown are dropped without
    /// touching the decoder, and the record survives.
    func testFailureRecordDropsPacketsInsideCooldown() throws {
        let sent = try encodedPackets(count: 5, ssrc: 0xBB)
        try XCTSkipIf(sent.count < 3, "AAC encoder produced no usable output on this host")

        let listener = try VoiceChannel(localSSRC: 0xCC, onSend: { _ in })
        let now = DispatchTime.now().uptimeNanoseconds
        listener.injectDecoderFailureForTesting(
            ssrc: 0xBB,
            record: VoiceChannel.DecoderFailureRecord(consecutiveInitFailures: 1, lastFailureNs: now)
        )
        var receivedAnyPCM = false
        listener.onMixedPCM = { samples in
            if !samples.isEmpty { receivedAnyPCM = true }
        }
        for packet in sent { listener.receive(packet) }
        listener.flushForTesting()

        XCTAssertFalse(receivedAnyPCM, "packets inside the cooldown must be dropped")
        XCTAssertEqual(
            listener.decoderFailuresForTesting[0xBB],
            VoiceChannel.DecoderFailureRecord(consecutiveInitFailures: 1, lastFailureNs: now),
            "dropping packets must not mutate the failure record")
    }
}
