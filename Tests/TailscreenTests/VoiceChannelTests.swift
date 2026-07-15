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
        // Concealment fills the gaps (capped at 2 silence frames per gap so
        // the fill can't overrun the playback queue), so total output should
        // approximate the sent duration (decoder priming may eat a frame;
        // late reordered packets are dropped as stale after their gap was
        // concealed).
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

    /// Packets dropped by the decoder-failure gate must still advance the
    /// per-SSRC sequence baseline, so the first packet after the cooldown
    /// is not misread as a gap (spurious discontinuity / concealment).
    func testGateDroppedPacketsKeepSequenceBaseline() throws {
        let sent = try encodedPackets(count: 12, ssrc: 0xBB)
        try XCTSkipIf(sent.count < 10, "AAC encoder produced no usable output on this host")

        let listener = try VoiceChannel(localSSRC: 0xCC, onSend: { _ in })
        var receivedAnyPCM = false
        listener.onMixedPCM = { samples in
            if !samples.isEmpty { receivedAnyPCM = true }
        }
        // Establish a healthy baseline with the first two packets.
        for packet in sent.prefix(2) { listener.receive(packet) }
        listener.flushForTesting()
        // Gate the SSRC (inside cooldown) and feed the middle packets —
        // all dropped, but the baseline must keep advancing. Without the
        // fix, this 8-packet hole reads as a discontinuity afterwards.
        listener.injectDecoderFailureForTesting(
            ssrc: 0xBB,
            record: VoiceChannel.DecoderFailureRecord(
                consecutiveInitFailures: 1,
                lastFailureNs: DispatchTime.now().uptimeNanoseconds
            )
        )
        for packet in sent.dropFirst(2).dropLast(2) { listener.receive(packet) }
        listener.flushForTesting()
        // Cooldown long elapsed: the tail packets flow again.
        listener.injectDecoderFailureForTesting(
            ssrc: 0xBB,
            record: VoiceChannel.DecoderFailureRecord(consecutiveInitFailures: 1, lastFailureNs: 1)
        )
        for packet in sent.suffix(2) { listener.receive(packet) }
        listener.flushForTesting()

        let stats = listener.currentStats
        XCTAssertEqual(stats.discontinuities, 0, "contiguous sequence must not resync after the gate")
        XCTAssertEqual(stats.concealedFrames, 0, "contiguous sequence must not conceal after the gate")
        XCTAssertTrue(receivedAnyPCM, "the retry after the cooldown must decode")
    }

    /// `concealedFrames` counts silence frames actually *emitted* — with
    /// no PCM sink attached nothing is emitted, so nothing is counted.
    func testConcealedFramesCountsOnlyEmittedFrames() throws {
        let sent = try encodedPackets(count: 10, ssrc: 0xBB)
        try XCTSkipIf(sent.count < 6, "AAC encoder produced no usable output on this host")

        let listener = try VoiceChannel(localSSRC: 0xCC, onSend: { _ in })
        // No onMixedPCM sink. Drop one packet mid-stream to force a gap.
        for (index, packet) in sent.enumerated() where index != 3 {
            listener.receive(packet)
        }
        listener.flushForTesting()
        XCTAssertEqual(
            listener.currentStats.concealedFrames, 0,
            "concealment that emitted nothing must not be counted")
    }

    /// Concealment per gap is capped below the playback queue's slack
    /// (`playbackSlackBuffers - 1` frames) so the silence fill can never
    /// overrun-drop the gap's next real decoded frame.
    func testConcealmentEmissionIsCappedPerGap() throws {
        let sent = try encodedPackets(count: 12, ssrc: 0xBB)
        try XCTSkipIf(sent.count < 10, "AAC encoder produced no usable output on this host")

        let listener = try VoiceChannel(localSSRC: 0xCC, onSend: { _ in })
        listener.onMixedPCM = { _ in }
        // Drop 4 consecutive packets: gapAction wants 4 concealment
        // frames, but emission must cap at playbackSlackBuffers - 1 == 2.
        for (index, packet) in sent.enumerated() where !(4...7).contains(index) {
            listener.receive(packet)
        }
        listener.flushForTesting()
        let stats = listener.currentStats
        XCTAssertEqual(stats.concealedFrames, VoiceChannel.playbackSlackBuffers - 1)
        XCTAssertEqual(stats.discontinuities, 0, "a 4-packet gap is still a concealed gap, not a resync")
    }
}
