import XCTest

@testable import TailscreenAudio
@testable import TailscreenProtocol
@testable import TailscreenViewer

/// Unit coverage for the portable viewer data-plane core. Everything is driven
/// through `ViewerSession`'s public seam (feed RTP + a clock, observe the sinks
/// and the emitted control bytes) using the package's real packetizers, so no
/// RTP bytes are hand-rolled and no socket/thread/timer is involved.
final class ViewerSessionTests: XCTestCase {

    // MARK: - Test doubles

    /// Video decoder stub: returns a fixed frame per AU and records the AUs it
    /// was handed. Can be flipped to throw to exercise the decode-failure PLI.
    private final class StubDecoder: VideoDecoding {
        var onDecodedFrame: ((any DecodedFrame) -> Void)?
        var onDecodeFailure: (() -> Void)?
        var decoded: [(au: Data, isKeyframe: Bool)] = []
        var shouldThrow = false
        let frame = DecodedVideoFrame(
            width: 4, height: 4,
            yPlane: [UInt8](repeating: 0x10, count: 16),
            uPlane: [UInt8](repeating: 0x80, count: 4),
            vPlane: [UInt8](repeating: 0x80, count: 4)
        )
        func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) {
            if shouldThrow {
                onDecodeFailure?()
                return
            }
            decoded.append((accessUnit, isKeyframe))
            onDecodedFrame?(frame)  // synchronous delivery, inside decode
        }
    }

    /// Models an asynchronous backend (VideoToolbox): `decode` returns without
    /// delivering; the frame arrives later, when `flush()` is called (standing
    /// in for the VT output callback, already hopped to the session's queue).
    private final class AsyncStubDecoder: VideoDecoding {
        var onDecodedFrame: ((any DecodedFrame) -> Void)?
        var onDecodeFailure: (() -> Void)?
        private var pending: [DecodedVideoFrame] = []
        let frame = DecodedVideoFrame(
            width: 8, height: 8,
            yPlane: [UInt8](repeating: 0x10, count: 64),
            uPlane: [UInt8](repeating: 0x80, count: 16),
            vPlane: [UInt8](repeating: 0x80, count: 16)
        )
        func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) {
            pending.append(frame)  // not delivered yet — async backend
        }
        func flush() {
            for frame in pending { onDecodedFrame?(frame) }
            pending.removeAll()
        }
    }

    private final class StubVideoSink: VideoSink {
        var frames: [DecodedVideoFrame] = []
        func present(_ frame: any DecodedFrame) {
            if let frame = frame as? DecodedVideoFrame { frames.append(frame) }
        }
    }

    private final class StubAudioSink: AudioSink {
        var pcm: [[Float]] = []
        func play(_ pcm: [Float]) { self.pcm.append(pcm) }
    }

    /// Collects the outbound control bytes the session hands to the host, and
    /// classifies them for assertions.
    private final class ControlCollector {
        var datagrams: [Data] = []
        var send: (Data) -> Void { { [weak self] in self?.datagrams.append($0) } }
        func kinds() -> [ScreenShareControlMessage] {
            datagrams.compactMap { ScreenShareControlMessage.decode($0) }
        }
        func count(of kind: ScreenShareControlMessage) -> Int {
            kinds().filter { $0 == kind }.count
        }
    }

    private let fullCaps: ScreenShareCaps = [.nack, .receiverReport, .fec]

    // MARK: - Helpers

    /// One AVCC access unit whose single NAL is large enough to force FU-A
    /// fragmentation, so the video path exercises multi-packet reassembly.
    private func makeAVCC(byteCount: Int = 4000, marker: UInt8 = 0x65) -> Data {
        var nal = Data([marker])  // type 5 = IDR slice for H.264
        nal.append(contentsOf: (0..<(byteCount - 1)).map { UInt8($0 & 0xFF) })
        var avcc = Data()
        let len = UInt32(nal.count)
        avcc.append(UInt8((len >> 24) & 0xFF))
        avcc.append(UInt8((len >> 16) & 0xFF))
        avcc.append(UInt8((len >> 8) & 0xFF))
        avcc.append(UInt8(len & 0xFF))
        avcc.append(nal)
        return avcc
    }

    // MARK: - Video

    func testVideoAccessUnitReachesSinkAsFrame() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC())
        let packets = packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 42, startSequence: 0)
        XCTAssertGreaterThan(packets.count, 1, "AU should fragment into multiple RTP packets")

        for packet in packets {
            session.receiveRTP(packet)
        }

        XCTAssertEqual(sink.frames.count, 1, "one AU should present exactly one stub frame")
        XCTAssertEqual(decoder.decoded.count, 1)
        XCTAssertTrue(decoder.decoded.first?.isKeyframe ?? false, "IDR AU should be flagged keyframe")
        XCTAssertEqual(sink.frames.first?.width, 4)
    }

    func testGapEmitsNackFeedback() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let packetizer = H264Packetizer()
        session.markKeyframeSeenForTesting()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        // Small AU → single packet per seq; build a run of single-packet AUs so
        // seq numbers advance one per AU and a hole is a clean one-packet gap.
        var packets: [Data] = []
        for i in 0..<8 {
            let p = packetizer.packetize(
                nals: nals, timestamp: UInt32(9000 + i * 3000), ssrc: 42, startSequence: UInt16(i)
            )
            packets.append(contentsOf: p)
        }

        // Deliver everything except seq 2; the newer packets piling up behind
        // the hole make the gap NACK-eligible (count tolerance) with no clock.
        for (i, packet) in packets.enumerated() where i != 2 {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 0)

        let nacks = control.count(of: .nack)
        let plis = control.count(of: .pli)
        XCTAssertGreaterThan(nacks + plis, 0, "a real gap must surface a NACK or PLI to the host")
    }

    func testDecodeFailureRequestsKeyframe() {
        let decoder = StubDecoder()
        decoder.shouldThrow = true
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: [.receiverReport], decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC())
        for packet in packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 7, startSequence: 0) {
            session.receiveRTP(packet)
        }

        XCTAssertEqual(sink.frames.count, 0)
        XCTAssertGreaterThan(control.count(of: .pli), 0, "decode failure should request a keyframe")
    }

    // MARK: - Observation hooks (stats overlay)

    /// The optional `onPLISent` hook fires whenever the session emits a PLI —
    /// here via a decode failure — so a host stats overlay can count keyframe
    /// requests without re-parsing the outbound control bytes.
    func testOnPLISentHookFiresOnDecodeFailure() {
        let decoder = StubDecoder()
        decoder.shouldThrow = true
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: [.receiverReport], decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )
        var plis = 0
        session.onPLISent = { plis += 1 }

        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC())
        for packet in packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 7, startSequence: 0) {
            session.receiveRTP(packet)
        }

        XCTAssertEqual(plis, control.count(of: .pli), "onPLISent must fire once per emitted PLI")
        XCTAssertGreaterThan(plis, 0)
    }

    /// `onNACKSent` fires alongside every emitted NACK; a real gap surfaces at
    /// least one of a NACK or a PLI, and whichever fires is mirrored by its hook.
    func testOnNACKSentHookFiresWithNack() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )
        var nacks = 0
        var plis = 0
        session.onNACKSent = { nacks += 1 }
        session.onPLISent = { plis += 1 }

        let packetizer = H264Packetizer()
        session.markKeyframeSeenForTesting()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        var packets: [Data] = []
        for i in 0..<8 {
            packets.append(
                contentsOf: packetizer.packetize(
                    nals: nals, timestamp: UInt32(9000 + i * 3000), ssrc: 42, startSequence: UInt16(i)))
        }
        for (i, packet) in packets.enumerated() where i != 2 {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 0)

        XCTAssertEqual(nacks, control.count(of: .nack), "onNACKSent must mirror emitted NACKs")
        XCTAssertEqual(plis, control.count(of: .pli), "onPLISent must mirror emitted PLIs")
        XCTAssertGreaterThan(nacks + plis, 0)
    }

    /// `onFECRecovered` fires once per FEC-recovered packet, so the overlay's
    /// recovery counter tracks the same events the extended RR reports.
    func testOnFECRecoveredHookFiresOnRecovery() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = fecSession(decoder, sink, control)
        var recovered = 0
        session.onFECRecovered = { recovered += 1 }

        let (packets, parity) = makeFECGroup(base: 0, count: 5, ssrc: 5)
        session.receiveRTP(parity)
        for (i, packet) in packets.enumerated() where i != 4 {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 1_000_000)

        XCTAssertEqual(recovered, 1, "one FEC recovery should fire onFECRecovered exactly once")
    }

    /// An async decoder delivers frames out-of-band (after `decode` returns) —
    /// the session presents whatever `onDecodedFrame` hands it, whenever it
    /// arrives, so a VideoToolbox-style backend works through the same seam.
    func testAsyncDecoderDeliversFramesOutOfBand() {
        let decoder = AsyncStubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC())
        for packet in packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 42, startSequence: 0) {
            session.receiveRTP(packet)
        }

        XCTAssertEqual(sink.frames.count, 0, "an async decoder hasn't delivered yet")
        decoder.flush()
        XCTAssertEqual(sink.frames.count, 1, "the deferred frame reaches the sink once emitted")
        XCTAssertEqual(sink.frames.first?.width, 8)
    }

    // MARK: - FEC ingest

    /// Build N contiguous single-packet IDR AUs (one RTP packet each, seqs
    /// `base..<base+N`, one ssrc) plus the XOR parity datagram covering them.
    private func makeFECGroup(
        base: UInt16, count: Int, ssrc: UInt32
    ) -> (packets: [Data], parity: Data) {
        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        var packets: [Data] = []
        for i in 0..<count {
            let p = packetizer.packetize(
                nals: nals, timestamp: UInt32(9000 + i * 3000), ssrc: ssrc,
                startSequence: base &+ UInt16(i))
            precondition(p.count == 1, "200-byte AU should be a single RTP packet")
            packets.append(p[0])
        }
        let body = FECCodec.parityBody(for: packets[0..<count])
        let parity = ScreenShareControlMessage.encodeFEC(baseSeq: base, count: count, body: body)
        return (packets, parity)
    }

    private func fecSession(
        _ decoder: StubDecoder, _ sink: StubVideoSink, _ control: ControlCollector,
        serverFEC: Bool = true
    ) -> ViewerSession {
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send)
        let serverCaps: ScreenShareCaps = serverFEC ? fullCaps : [.nack, .receiverReport]
        session.receiveRTP(ScreenShareControlMessage.encodeHelloAck(ssrc: 5, caps: serverCaps))
        // FEC suites drive P-frame-only streams and assert on recovered frame
        // counts; open the pre-keyframe gate so the mechanics under test stay
        // observable.
        session.markKeyframeSeenForTesting()
        return session
    }

    /// Parity-first ordering (the buffer arms on the first parity, then solves
    /// as the completing member arrives): one lost packet in a group is
    /// recovered with zero NACK/PLI and the missing AU still reaches the sink.
    func testFECRecoversSingleLoss() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = fecSession(decoder, sink, control)

        let (packets, parity) = makeFECGroup(base: 0, count: 5, ssrc: 5)
        let missing = 4  // the tail (marker) packet — the load-bearing recovery

        // Parity first arms the machinery and buffers the group; members then
        // fill in until exactly one is missing, at which point it solves.
        session.receiveRTP(parity)
        for (i, packet) in packets.enumerated() where i != missing {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 1_000_000)

        XCTAssertEqual(sink.frames.count, 5, "the lost AU should be FEC-recovered, so all 5 present")
        XCTAssertEqual(control.count(of: .pli), 0, "a single loss recovered by FEC needs no PLI")
        XCTAssertEqual(control.count(of: .nack), 0, "a single loss recovered by FEC needs no NACK")
    }

    /// Members-first ordering with the buffer already armed: the parity solves
    /// immediately on arrival (the `trySolve` path, distinct from the
    /// solve-on-media path above). A prior fully-received group does the arming.
    func testFECImmediateSolveOnParityArrival() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = fecSession(decoder, sink, control)

        // Group A: parity-first, fully delivered — arms the buffer, recovers
        // nothing (nothing was lost).
        let (aPackets, aParity) = makeFECGroup(base: 0, count: 5, ssrc: 5)
        session.receiveRTP(aParity)
        for packet in aPackets { session.receiveRTP(packet) }
        XCTAssertEqual(sink.frames.count, 5)

        // Group B: all members but the middle one arrive (retained because the
        // buffer is now armed), then the parity solves the hole immediately.
        let (bPackets, bParity) = makeFECGroup(base: 5, count: 5, ssrc: 5)
        let missing = 2
        for (i, packet) in bPackets.enumerated() where i != missing {
            session.receiveRTP(packet)
        }
        session.receiveRTP(bParity)
        session.tick(nowNs: 1_000_000)

        XCTAssertEqual(sink.frames.count, 10, "group B's lost AU should solve on parity arrival")
        XCTAssertEqual(control.count(of: .pli), 0)
    }

    /// A recovered packet counts as *received* in the RR (residual loss, the
    /// bitrate arm) while the extended RR's `fecRecovered` field carries the
    /// raw-loss signal the sharer's FEC arm needs.
    func testFECRecoveryCountedInReceiverReport() throws {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = fecSession(decoder, sink, control)

        let (packets, parity) = makeFECGroup(base: 0, count: 5, ssrc: 5)
        session.receiveRTP(parity)
        for (i, packet) in packets.enumerated() where i != 3 {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 1_000_000_000)

        let rrData = try XCTUnwrap(
            control.datagrams.first { ScreenShareControlMessage.decode($0) == .receiverReport })
        let report = try XCTUnwrap(ScreenShareControlMessage.decodeReceiverReport(rrData))
        XCTAssertEqual(report.fecRecovered, 1, "one FEC recovery should be reported")

        // The next report resets the delta (drained on send).
        control.datagrams.removeAll()
        session.tick(nowNs: 3_000_000_000)
        if let next = control.datagrams.first(where: { ScreenShareControlMessage.decode($0) == .receiverReport }) {
            XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(next)?.fecRecovered, 0)
        }
    }

    /// Parity is inert unless BOTH sides negotiated `.fec` — a sharer that
    /// never advertised it (so the viewer's `.fec` cap goes unmatched) leaves
    /// the loss unrecovered, exactly like a legacy peer.
    func testParityIgnoredWithoutNegotiatedFEC() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = fecSession(decoder, sink, control, serverFEC: false)

        let (packets, parity) = makeFECGroup(base: 0, count: 5, ssrc: 5)
        session.receiveRTP(parity)
        for (i, packet) in packets.enumerated() where i != 4 {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 1_000_000)

        XCTAssertEqual(sink.frames.count, 4, "without negotiated FEC the lost AU is not recovered")
    }

    // MARK: - Audio

    func testOpusAudioReachesAudioSink() throws {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let audioSink = StubAudioSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: audioSink, onControlToSend: control.send
        )

        let encoder = try OpusVoiceEncoder()
        let frame = (0..<OpusVoiceEncoder.frameSamples).map { i in
            Float(0.4 * sin(2 * .pi * 440 * Double(i) / 48_000))
        }
        let opus = try XCTUnwrap(try encoder.encode(pcm: frame))
        let packetizer = AudioRTPPacketizer(ssrc: RTPHeader.sharerVoiceSSRC)
        let rtp = packetizer.packetize(au: opus)

        session.receiveRTP(rtp)

        XCTAssertEqual(audioSink.pcm.count, 1, "one audio RTP packet should decode to one PCM frame")
        XCTAssertEqual(audioSink.pcm.first?.count, OpusVoiceEncoder.frameSamples)
    }

    /// With an `onAudioDatagram` passthrough, inbound audio RTP is forwarded
    /// verbatim and the built-in Opus path is skipped — the seam a host with
    /// its own audio pipeline (macOS's VoiceChannel) uses.
    func testAudioPassthroughForwardsRawDatagram() throws {
        var forwarded: [Data] = []
        let audioSink = StubAudioSink()
        let session = ViewerSession(
            caps: fullCaps, decoder: StubDecoder(), videoSink: StubVideoSink(),
            audioSink: audioSink, onControlToSend: { _ in },
            onAudioDatagram: { forwarded.append($0) }
        )

        let encoder = try OpusVoiceEncoder()
        let frame = (0..<OpusVoiceEncoder.frameSamples).map { i in
            Float(0.3 * sin(2 * .pi * 440 * Double(i) / 48_000))
        }
        let opus = try XCTUnwrap(try encoder.encode(pcm: frame))
        let rtp = AudioRTPPacketizer(ssrc: RTPHeader.sharerVoiceSSRC).packetize(au: opus)

        session.receiveRTP(rtp)

        XCTAssertEqual(forwarded, [rtp], "the exact datagram is forwarded for the host to demux/decode")
        XCTAssertEqual(audioSink.pcm.count, 0, "the built-in Opus path is skipped when passthrough is set")
    }

    // MARK: - Handshake + feedback cadence

    func testStartEmitsHelloAdvertisingCaps() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        session.start()

        XCTAssertEqual(control.datagrams.count, 1)
        let hello = try? XCTUnwrap(control.datagrams.first)
        XCTAssertEqual(ScreenShareControlMessage.decode(control.datagrams[0]), .hello)
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloCaps(hello ?? Data()), fullCaps)
    }

    func testHelloAckLearnsSsrcAndServerCaps() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let ack = ScreenShareControlMessage.encodeHelloAck(
            ssrc: 77, caps: [.nack, .receiverReport, .fec, .remoteControl]
        )
        session.receiveRTP(ack)

        XCTAssertEqual(session.assignedSSRC, 77)
        XCTAssertTrue(session.serverCaps.contains(.remoteControl))
        XCTAssertTrue(session.serverCaps.contains(.fec))
    }

    /// A legacy sharer (no cap support) replies with the plain 5-byte HELLO_ACK
    /// `[0x04][ssrc:4]`. The tolerant `decodeHelloAckCaps` parser must still
    /// learn the SSRC (so audio relay + admission proceed) with empty
    /// serverCaps, so the whole loss-recovery matrix degrades to PLI-only — the
    /// viewer never advertises NACK/FEC behavior a legacy sharer can't honor.
    func testLegacyHelloAckLearnsSsrcWithoutCaps() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        // The 5-byte legacy encoder — no serverCaps byte.
        let ack = ScreenShareControlMessage.encodeHelloAck(ssrc: 91)
        XCTAssertEqual(ack.count, 5, "legacy HELLO_ACK is exactly 5 bytes")
        session.receiveRTP(ack)

        XCTAssertEqual(session.assignedSSRC, 91, "legacy 5-byte ack must still assign the SSRC")
        XCTAssertEqual(session.serverCaps, [], "a legacy ack advertises no caps")
        XCTAssertFalse(session.isPendingApproval)
    }

    func testTickEmitsReceiverReportAfterVideo() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        // Negotiate FEC so the RR uses the extended (recovery-field) layout.
        session.receiveRTP(ScreenShareControlMessage.encodeHelloAck(ssrc: 5, caps: fullCaps))

        let packetizer = H264Packetizer()
        session.markKeyframeSeenForTesting()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        for packet in packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 5, startSequence: 0) {
            session.receiveRTP(packet)
        }

        session.tick(nowNs: 1_000_000_000)

        XCTAssertGreaterThan(control.count(of: .receiverReport), 0, "tick should emit a receiver report")
        let rr = control.datagrams.first { ScreenShareControlMessage.decode($0) == .receiverReport }
        let decoded = ScreenShareControlMessage.decodeReceiverReport(try! XCTUnwrap(rr))
        XCTAssertNotNil(decoded)
    }

    func testNoReceiverReportWithoutCapability() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: [], decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let packetizer = H264Packetizer()
        session.markKeyframeSeenForTesting()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        for packet in packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 5, startSequence: 0) {
            session.receiveRTP(packet)
        }
        session.tick(nowNs: 2_000_000_000)

        XCTAssertEqual(control.count(of: .receiverReport), 0)
    }

    func testServerByeStopsSession() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )
        XCTAssertFalse(session.isStopped)
        XCTAssertNil(session.closeReason, "a live session has no close reason")
        session.receiveRTP(ScreenShareControlMessage.encode(.serverBye))
        XCTAssertTrue(session.isStopped)
        XCTAssertEqual(session.closeReason, .sharerStopped)
        XCTAssertFalse(session.wasDenied, "an ordinary stop is not a deny")
    }

    /// HELLO_DENY (0x08) — the sharer declining (or kicking) this viewer. The
    /// deny protocol is HELLO_DENY followed by SERVER_BYE, and the trailing
    /// bye must NOT relabel the deny as an ordinary sharer stop: first cause
    /// wins, or every declined viewer reads "the sharer stopped sharing".
    func testHelloDenyMarksDeniedAndSurvivesTheTrailingServerBye() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        // The deny control byte, constructed exactly as the session parses it
        // (a bare `[0x08]` — HELLO_DENY carries no payload).
        session.receiveRTP(ScreenShareControlMessage.encode(.helloDenied))
        XCTAssertTrue(session.wasDenied)
        XCTAssertTrue(session.isStopped, "a denied viewer is a stopped viewer")
        XCTAssertEqual(session.closeReason, .deniedOrKicked)

        // The SERVER_BYE the server chases the deny with.
        session.receiveRTP(ScreenShareControlMessage.encode(.serverBye))
        XCTAssertEqual(
            session.closeReason, .deniedOrKicked,
            "the trailing SERVER_BYE must not relabel a deny as a sharer stop")
        XCTAssertTrue(session.wasDenied)
    }

    /// The legacy flags are untouched by the close-reason addition: a denied
    /// session still reads exactly as it did to callers of `wasDenied` /
    /// `isStopped`, and admission state is unaffected by a deny that arrives
    /// while parked pending.
    func testHelloDenyAfterPendingLeavesAdmissionStateUnassigned() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        session.receiveRTP(ScreenShareControlMessage.encode(.helloPending))
        XCTAssertTrue(session.isPendingApproval)
        XCTAssertNil(session.closeReason, "pending is a wait, not an ending")

        session.receiveRTP(ScreenShareControlMessage.encode(.helloDenied))
        XCTAssertTrue(session.wasDenied)
        XCTAssertEqual(session.closeReason, .deniedOrKicked)
        XCTAssertNil(
            session.assignedSSRC,
            "a viewer denied at the gate was never admitted — the host words this as declined")
    }

    // MARK: - Pre-keyframe gating

    func testPreKeyframeAUsAreDroppedAndCounted() {
        let decoder = StubDecoder()
        let sink = StubVideoSink()
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )

        let packetizer = H264Packetizer()
        // Two P-frames before any keyframe: both must be dropped and counted,
        // never handed to the decoder (libavcodec would log two lines each).
        for i in 0..<2 {
            let p = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
            for pkt in packetizer.packetize(
                nals: p, timestamp: UInt32(9000 + i * 3000), ssrc: 42,
                startSequence: UInt16(i))
            {
                session.receiveRTP(pkt)
            }
        }
        XCTAssertEqual(decoder.decoded.count, 0, "no AU may reach the decoder before a keyframe")
        XCTAssertEqual(session.preKeyframeDropCount, 2)

        // The keyframe opens the gate; a P-frame after it decodes normally.
        // Small IDR on purpose: the default makeAVCC() fragments across several
        // RTP packets, which would occupy seqs 2..N and collide with the
        // P-frame at seq 3 — the depacketizer would then drop the P-frame as a
        // duplicate and this test would fail for sequencing reasons, not
        // gating ones (it did).
        let idr = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200))
        for pkt in packetizer.packetize(nals: idr, timestamp: 15000, ssrc: 42, startSequence: 2) {
            session.receiveRTP(pkt)
        }
        let post = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        for pkt in packetizer.packetize(nals: post, timestamp: 18000, ssrc: 42, startSequence: 3) {
            session.receiveRTP(pkt)
        }
        XCTAssertEqual(decoder.decoded.count, 2, "keyframe + post-keyframe P-frame both decode")
        XCTAssertEqual(session.preKeyframeDropCount, 2, "the counter stops once the gate opens")
    }

    // MARK: - Keyframe request while blank

    /// The sharer forces a keyframe on admission, but only once. A live
    /// Mac→Windows session lost that IDR and stayed blank for the whole session
    /// on a clean link: 112 access units in three seconds, every one a P-frame,
    /// nothing left to ask again. These cover the retry that closes it.
    private func makeAdmittedSession(
        _ decoder: StubDecoder, _ sink: StubVideoSink, _ control: ControlCollector
    ) -> ViewerSession {
        let session = ViewerSession(
            caps: fullCaps, decoder: decoder, videoSink: sink,
            audioSink: nil, onControlToSend: control.send
        )
        session.receiveRTP(ScreenShareControlMessage.encodeHelloAck(ssrc: 7, caps: fullCaps))
        return session
    }

    func testBlankAdmittedViewerRequestsAKeyframeOnCadence() {
        let control = ControlCollector()
        let session = makeAdmittedSession(StubDecoder(), StubVideoSink(), control)
        XCTAssertEqual(control.count(of: .pli), 0, "admission itself must not ask")

        session.tick(nowNs: 1_000)
        XCTAssertEqual(control.count(of: .pli), 1, "first tick after admission asks straight away")

        session.tick(nowNs: 2_000)
        XCTAssertEqual(control.count(of: .pli), 1, "inside the interval, no duplicate request")

        session.tick(nowNs: 1_000 + ViewerSession.keyframeRequestIntervalNs)
        XCTAssertEqual(control.count(of: .pli), 2, "one request per interval while still blank")
    }

    func testKeyframeRequestWaitsForAdmission() {
        let control = ControlCollector()
        let session = ViewerSession(
            caps: fullCaps, decoder: StubDecoder(), videoSink: StubVideoSink(),
            audioSink: nil, onControlToSend: control.send
        )

        // No HELLO_ACK: nothing has admitted us, so there is nobody to serve a
        // keyframe and a viewer parked at the approval prompt must stay quiet.
        session.tick(nowNs: 1_000)
        session.tick(nowNs: 5 * ViewerSession.keyframeRequestIntervalNs)
        XCTAssertEqual(control.count(of: .pli), 0)
    }

    func testPFramesAloneDoNotSatisfyTheKeyframeRequest() {
        let control = ControlCollector()
        let session = makeAdmittedSession(StubDecoder(), StubVideoSink(), control)
        session.tick(nowNs: 1_000)
        XCTAssertEqual(control.count(of: .pli), 1)

        // Exactly the observed failure: an access unit assembles cleanly and is
        // dropped by the pre-keyframe gate. That must not read as progress.
        let packetizer = H264Packetizer()
        let pFrame = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200, marker: 0x41))
        for pkt in packetizer.packetize(nals: pFrame, timestamp: 9000, ssrc: 7, startSequence: 0) {
            session.receiveRTP(pkt)
        }
        XCTAssertEqual(session.preKeyframeDropCount, 1, "the P-frame was assembled and dropped")

        session.tick(nowNs: 1_000 + ViewerSession.keyframeRequestIntervalNs)
        XCTAssertEqual(control.count(of: .pli), 2, "still blank, so still asking")
    }

    // MARK: - Diagnostics that separate look-alike faults

    /// The distinction the socket-drain hunt had to infer from arrival rates:
    /// an access unit that assembles and is thrown away as torn must not look
    /// like an access unit that never assembled.
    func testTornAccessUnitIsCountedSeparatelyFromOneThatNeverAssembles() {
        let control = ControlCollector()
        let session = makeAdmittedSession(StubDecoder(), StubVideoSink(), control)
        session.markKeyframeSeenForTesting()

        // Feed a fragmented AU with its first packet missing, then a marker
        // packet, so the AU completes torn rather than never completing.
        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC())
        let packets = packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 7, startSequence: 0)
        XCTAssertGreaterThan(packets.count, 2, "need a fragmented AU for this to mean anything")
        for packet in packets.dropFirst() {
            session.receiveRTP(packet)
        }

        let diagnostics = session.diagnostics
        XCTAssertGreaterThan(diagnostics.videoPacketsReceived, 0, "packets did arrive")
        XCTAssertEqual(diagnostics.accessUnitsAssembled, 0, "nothing survived to the decoder")
        XCTAssertGreaterThan(
            diagnostics.tornAUs, 0,
            "the torn AU must be visible — otherwise this is indistinguishable from no AU at all")
    }

    func testDiagnosticsNameTheCodecAndCountKeyframeRequests() {
        let control = ControlCollector()
        let session = makeAdmittedSession(StubDecoder(), StubVideoSink(), control)
        XCTAssertNil(session.diagnostics.codec, "no video yet, so nothing to claim")

        session.tick(nowNs: 1_000)
        XCTAssertEqual(
            session.diagnostics.keyframeRequests, 1,
            "the pre-keyframe retry is a keyframe request and must be counted as one")

        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200))
        for pkt in packetizer.packetize(nals: nals, timestamp: 9000, ssrc: 7, startSequence: 0) {
            session.receiveRTP(pkt)
        }
        XCTAssertEqual(session.diagnostics.codec, .h264, "payload type 96 is H.264")
    }

    func testKeyframeStopsTheRequests() {
        let decoder = StubDecoder()
        let control = ControlCollector()
        let session = makeAdmittedSession(decoder, StubVideoSink(), control)
        session.tick(nowNs: 1_000)
        XCTAssertEqual(control.count(of: .pli), 1)

        let packetizer = H264Packetizer()
        let idr = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200))
        for pkt in packetizer.packetize(nals: idr, timestamp: 9000, ssrc: 7, startSequence: 0) {
            session.receiveRTP(pkt)
        }
        XCTAssertEqual(decoder.decoded.count, 1, "the keyframe decoded")

        session.tick(nowNs: 1_000 + 5 * ViewerSession.keyframeRequestIntervalNs)
        XCTAssertEqual(
            control.count(of: .pli), 1,
            "once a keyframe has landed the decode-failure and NACK paths own recovery")
    }

    // MARK: - Decode-recovery ladder (opt-in escalation)

    /// Feed `count` single-packet IDR AUs starting at `startSeq` (the keyframe
    /// gate opens on the first), one distinct seq/timestamp per AU. Returns the
    /// next unused sequence number so episodes can be chained.
    @discardableResult
    private func feedAUs(_ session: ViewerSession, count: Int, startSeq: UInt16 = 0) -> UInt16 {
        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC(byteCount: 200))
        var seq = startSeq
        for _ in 0..<count {
            let packets = packetizer.packetize(
                nals: nals, timestamp: 9000 &+ UInt32(seq) &* 3000, ssrc: 7, startSequence: seq)
            for packet in packets {
                session.receiveRTP(packet)
            }
            seq &+= 1
        }
        return seq
    }

    /// With NEITHER ladder callback installed the session keeps the historical
    /// flat path: exactly one PLI per decode failure, no escalation. This is
    /// the behavior pin for hosts that don't opt in (including the macOS
    /// client, whose adapter never reports per-frame failures here at all).
    func testNoLadderCallbacksKeepsFlatPLIPerFailure() {
        let decoder = StubDecoder()
        decoder.shouldThrow = true
        let control = ControlCollector()
        let session = ViewerSession(
            caps: [.receiverReport], decoder: decoder, videoSink: StubVideoSink(),
            audioSink: nil, onControlToSend: control.send
        )
        var plis = 0
        session.onPLISent = { plis += 1 }

        feedAUs(session, count: 10)

        XCTAssertEqual(control.count(of: .pli), 10, "flat path: one PLI per decode failure")
        XCTAssertEqual(plis, 10, "onPLISent mirrors each flat-path PLI")
        XCTAssertEqual(session.diagnostics.decodeFailures, 10)
    }

    /// Ladder-mode assembly: a failing session with both callbacks installed,
    /// plus counters for every observable output.
    private struct LadderHarness {
        let session: ViewerSession
        let decoder: StubDecoder
        let control: ControlCollector
        let resets: Counter
        let fatals: Counter

        final class Counter {
            var value = 0
        }
    }

    private func makeLadderHarness() -> LadderHarness {
        let decoder = StubDecoder()
        decoder.shouldThrow = true
        let control = ControlCollector()
        let session = ViewerSession(
            caps: [.receiverReport], decoder: decoder, videoSink: StubVideoSink(),
            audioSink: nil, onControlToSend: control.send
        )
        let resets = LadderHarness.Counter()
        let fatals = LadderHarness.Counter()
        session.onDecoderResetNeeded = { resets.value += 1 }
        session.onDecodeFatal = { fatals.value += 1 }
        return LadderHarness(
            session: session, decoder: decoder, control: control, resets: resets, fatals: fatals)
    }

    /// With the callbacks installed, failures escalate instead of spamming
    /// PLIs: nothing below the first rung, one PLI at the keyframe rung, and
    /// nothing more until the next rung.
    func testLadderFiresKeyframeRungOnceAtThreshold() {
        let harness = makeLadderHarness()

        var seq = feedAUs(harness.session, count: DecodeRecovery.requestKeyframeFailureThreshold - 1)
        XCTAssertEqual(harness.control.count(of: .pli), 0, "below the first rung nothing fires")

        seq = feedAUs(harness.session, count: 1, startSeq: seq)
        XCTAssertEqual(harness.control.count(of: .pli), 1, "the keyframe rung asks exactly once")

        feedAUs(
            harness.session,
            count: DecodeRecovery.recreateSessionFailureThreshold - DecodeRecovery.requestKeyframeFailureThreshold - 1,
            startSeq: seq)
        XCTAssertEqual(harness.control.count(of: .pli), 1, "latched until the next rung")
        XCTAssertEqual(harness.resets.value, 0)
        XCTAssertEqual(harness.fatals.value, 0)
    }

    /// The reset rung fires `onDecoderResetNeeded` exactly once, with the PLI
    /// that asks for the keyframe the rebuilt decoder needs.
    func testLadderFiresResetRungOnceWithKeyframeRequest() {
        let harness = makeLadderHarness()

        let seq = feedAUs(harness.session, count: DecodeRecovery.recreateSessionFailureThreshold)
        XCTAssertEqual(harness.resets.value, 1, "the reset rung fires at its threshold")
        XCTAssertEqual(
            harness.control.count(of: .pli), 2,
            "keyframe rung + the reset rung's own keyframe request")
        XCTAssertEqual(harness.fatals.value, 0, "the terminal rung hasn't been reached")

        feedAUs(harness.session, count: 30, startSeq: seq)
        XCTAssertEqual(harness.resets.value, 1, "latched — each rung once per episode")
        XCTAssertEqual(harness.control.count(of: .pli), 2)
    }

    /// The terminal rung fires `onDecodeFatal` exactly once, after the reset
    /// rung already had its chance, and stays latched however long the
    /// failures continue.
    func testLadderFiresFatalRungOnceAtTerminalThreshold() {
        let harness = makeLadderHarness()

        var seq = feedAUs(harness.session, count: DecodeRecovery.surfaceErrorFailureThreshold - 1)
        XCTAssertEqual(harness.fatals.value, 0, "one failure short of the terminal rung")

        seq = feedAUs(harness.session, count: 1, startSeq: seq)
        XCTAssertEqual(harness.fatals.value, 1, "the terminal rung surfaces the stall")

        feedAUs(harness.session, count: 100, startSeq: seq)
        XCTAssertEqual(harness.fatals.value, 1, "latched — never re-surfaced within the episode")
        XCTAssertEqual(harness.resets.value, 1)
        XCTAssertEqual(harness.control.count(of: .pli), 2)
    }

    /// A successful decode resets the consecutive counter — a fresh failing
    /// run needs the full threshold again — and clears the per-episode
    /// latches, so a NEW episode walks the rungs again.
    func testSuccessfulDecodeResetsLadderCounterAndLatches() {
        let harness = makeLadderHarness()

        // Fail one short of the first rung, then decode one frame.
        var seq = feedAUs(harness.session, count: DecodeRecovery.requestKeyframeFailureThreshold - 1)
        harness.decoder.shouldThrow = false
        seq = feedAUs(harness.session, count: 1, startSeq: seq)
        harness.decoder.shouldThrow = true

        // The next run starts from zero: the same one-short count fires
        // nothing, and the threshold-th consecutive failure fires the rung.
        seq = feedAUs(
            harness.session, count: DecodeRecovery.requestKeyframeFailureThreshold - 1, startSeq: seq)
        XCTAssertEqual(
            harness.control.count(of: .pli), 0,
            "the success reset the counter — 4 + 4 non-consecutive failures fire nothing")
        seq = feedAUs(harness.session, count: 1, startSeq: seq)
        XCTAssertEqual(harness.control.count(of: .pli), 1, "five consecutive failures fire the rung")

        // Walk this episode to the terminal rung, recover, then fail again:
        // the cleared latches let every rung fire a second time.
        seq = feedAUs(
            harness.session,
            count: DecodeRecovery.surfaceErrorFailureThreshold, startSeq: seq)
        XCTAssertEqual(harness.resets.value, 1)
        XCTAssertEqual(harness.fatals.value, 1)

        harness.decoder.shouldThrow = false
        seq = feedAUs(harness.session, count: 1, startSeq: seq)
        harness.decoder.shouldThrow = true

        seq = feedAUs(
            harness.session, count: DecodeRecovery.surfaceErrorFailureThreshold, startSeq: seq)
        XCTAssertEqual(harness.resets.value, 2, "a fresh episode reaches the reset rung again")
        XCTAssertEqual(harness.fatals.value, 2, "and the terminal rung again")
        XCTAssertEqual(
            harness.control.count(of: .pli), 4,
            "two PLI-bearing rungs (keyframe + reset) per episode, two episodes")
    }
}
