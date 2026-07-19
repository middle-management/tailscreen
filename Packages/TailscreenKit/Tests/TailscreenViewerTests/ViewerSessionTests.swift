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
        var decoded: [(au: Data, isKeyframe: Bool)] = []
        var shouldThrow = false
        struct Boom: Error {}
        let frame = DecodedVideoFrame(
            width: 4, height: 4,
            yPlane: [UInt8](repeating: 0x10, count: 16),
            uPlane: [UInt8](repeating: 0x80, count: 4),
            vPlane: [UInt8](repeating: 0x80, count: 4)
        )
        func decode(accessUnit: Data, isKeyframe: Bool) throws -> [DecodedVideoFrame] {
            if shouldThrow { throw Boom() }
            decoded.append((accessUnit, isKeyframe))
            return [frame]
        }
    }

    private final class StubVideoSink: VideoSink {
        var frames: [DecodedVideoFrame] = []
        func present(_ frame: DecodedVideoFrame) { frames.append(frame) }
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
        session.receiveRTP(ScreenShareControlMessage.encode(.serverBye))
        XCTAssertTrue(session.isStopped)
    }
}
