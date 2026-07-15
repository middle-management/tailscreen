import XCTest

@testable import Tailscreen

/// Deterministic, seeded byte-level fuzz harness for every parser that faces
/// hostile bytes: the framed TCP control parser, the RTP depacketizers, the
/// UDP control decoders, the audio depacketizer, and the helper-wire
/// parameter-set decoder.
///
/// Four strategies per target: random bytes, truncations of valid encodes,
/// bit-flips of valid frames, and length-field mutations. The invariant is
/// always the same shape — **no crash, no hang, clean reject** (nil / `[]` /
/// no message) or a sane parse. "No hang" is structural: every parser here is
/// synchronous and loop-bounded by input length, and the harness feeds bounded
/// inputs, so a wedge surfaces as the suite blowing its CI timeout.
///
/// Determinism rules (see CLAUDE.md): no `Date()`, no unseeded randomness, no
/// sleeps. Every iteration derives its seed from the loop index, and every
/// failure message prints that seed so a red run reproduces exactly.
/// `multiplier` scales the iteration budgets: 1 for PR CI (the whole suite
/// stays in low single-digit seconds), ~50 for the nightly soak
/// (`SoakTests`).
struct ParserFuzzHarness {
    let multiplier: Int
    let baseSeed: UInt64

    init(multiplier: Int = 1, baseSeed: UInt64 = 0x7A11_5C12_EE00_0001) {
        self.multiplier = multiplier
        self.baseSeed = baseSeed
    }

    private func seed(_ index: Int) -> UInt64 {
        baseSeed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
    }

    private func randomData(count: Int, using rng: inout SeededRNG) -> Data {
        var data = Data(capacity: count)
        for _ in 0..<count {
            data.append(UInt8.random(in: 0...255, using: &rng))
        }
        return data
    }

    /// Feed `stream` into a parser in seeded random chunks (exercising the
    /// incremental path), pumping `next()` as we go. Returns every message
    /// produced.
    private func pumpTCPParser(
        _ stream: Data, using rng: inout SeededRNG
    ) -> [ScreenShareMessage] {
        var parser = ScreenShareMessageParser()
        var messages: [ScreenShareMessage] = []
        var offset = stream.startIndex
        while offset < stream.endIndex {
            let remaining = stream.distance(from: offset, to: stream.endIndex)
            let take = Int.random(in: 1...max(1, min(remaining, 97)), using: &rng)
            let end = stream.index(offset, offsetBy: take)
            parser.append(Data(stream[offset..<end]))
            offset = end
            // A nil from next() can mean "need more bytes" OR "known type
            // with an undecodable payload" — keep pumping a bounded number
            // of times so a rejected frame doesn't strand the ones behind it.
            for _ in 0..<8 {
                if let message = parser.next() { messages.append(message) }
            }
        }
        for _ in 0..<8 {
            if let message = parser.next() { messages.append(message) }
        }
        return messages
    }

    // MARK: - Target: ScreenShareMessageParser (framed TCP)

    func fuzzTCPParserRandomBytes() {
        for i in 0..<(400 * multiplier) {
            var rng = SeededRNG(seed: seed(i))
            let stream = randomData(count: Int.random(in: 0...4096, using: &rng), using: &rng)
            _ = pumpTCPParser(stream, using: &rng)  // invariant: no crash, no hang
        }
    }

    /// Every strict prefix of a valid frame must parse to nothing (the frame
    /// is incomplete) without crashing or corrupting the parser.
    func fuzzTCPParserTruncations() {
        for (i, message) in Self.sampleTCPMessages().enumerated() {
            let full = message.encode()
            for cut in 0..<full.count {
                var parser = ScreenShareMessageParser()
                parser.append(full.prefix(cut))
                XCTAssertNil(
                    parser.next(),
                    "strict prefix (\(cut)/\(full.count) bytes) of sample #\(i) must not yield a message")
                XCTAssertFalse(parser.isCorrupt, "a truncated frame is incomplete, not corrupt")
                // The rest of the bytes complete the frame.
                parser.append(full.suffix(full.count - cut))
                XCTAssertNotNil(parser.next(), "completing sample #\(i) after the cut must parse")
            }
        }
    }

    /// Bit-flips inside one frame's *payload* must never desync the following
    /// intact frame — framing is header-driven, so a corrupt payload decodes
    /// to nil (or garbage) but the next frame's boundary is still found.
    func fuzzTCPParserPayloadBitFlips() {
        let follower = ScreenShareMessage.controlReleased  // distinctive, empty payload
        for i in 0..<(300 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            let samples = Self.sampleTCPMessages()
            var frame1 = samples[i % samples.count].encode()
            let payloadLen = frame1.count - ScreenShareMessage.headerSize
            guard payloadLen > 0 else { continue }
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let bytePos = ScreenShareMessage.headerSize + Int.random(in: 0..<payloadLen, using: &rng)
                let bit = UInt8(1) << Int.random(in: 0..<8, using: &rng)
                frame1[frame1.startIndex + bytePos] ^= bit
            }
            var stream = frame1
            stream.append(follower.encode())
            let messages = pumpTCPParser(stream, using: &rng)
            let followerSeen = messages.contains { message in
                if case .controlReleased = message { return true }
                return false
            }
            XCTAssertTrue(
                followerSeen,
                "payload bit-flip desynced the following intact frame (seed=\(caseSeed))")
        }
    }

    /// Length-field mutations: the poison contract. A declared length over
    /// `maxPayloadLength` latches `isCorrupt`, `next()` returns nil forever,
    /// and post-poison appends don't grow the buffer.
    func fuzzTCPParserLengthMutations() {
        let full = ScreenShareMessage.controlRequest.encode()
        let oversized = [
            UInt32(ScreenShareMessage.maxPayloadLength + 1),
            UInt32(ScreenShareMessage.maxPayloadLength) + 2,
            0xFFFF_FFFF
        ]
        for badLen in oversized {
            var frame = full
            let lenStart = frame.startIndex + 1
            frame[lenStart] = UInt8((badLen >> 24) & 0xFF)
            frame[lenStart + 1] = UInt8((badLen >> 16) & 0xFF)
            frame[lenStart + 2] = UInt8((badLen >> 8) & 0xFF)
            frame[lenStart + 3] = UInt8(badLen & 0xFF)
            var parser = ScreenShareMessageParser()
            parser.append(frame)
            XCTAssertNil(parser.next(), "oversized declared length \(badLen) must not parse")
            XCTAssertTrue(parser.isCorrupt, "oversized declared length \(badLen) must poison the parser")
            // Post-poison feed: 10 MB in chunks; next() stays nil throughout
            // (the parser drops the bytes rather than buffering them).
            let chunk = Data(repeating: 0x41, count: 1 << 20)
            for _ in 0..<10 {
                parser.append(chunk)
                XCTAssertNil(parser.next(), "poisoned parser must never yield again")
            }
        }
        // Off-by-one and zero mutations on a frame with a real payload: no
        // crash. The stream may desync (leftover payload bytes reparse as a
        // bogus header, possibly poisoning) — that's the documented TCP
        // framing model, so only no-crash is asserted here.
        let payloadFrame = ScreenShareMessage.controlRevoked(reason: "mutation-sample").encode()
        let realLen = UInt32(payloadFrame.count - ScreenShareMessage.headerSize)
        for badLen: UInt32 in [0, realLen - 1, realLen + 1] {
            var frame = payloadFrame
            let lenStart = frame.startIndex + 1
            frame[lenStart] = UInt8((badLen >> 24) & 0xFF)
            frame[lenStart + 1] = UInt8((badLen >> 16) & 0xFF)
            frame[lenStart + 2] = UInt8((badLen >> 8) & 0xFF)
            frame[lenStart + 3] = UInt8(badLen & 0xFF)
            var parser = ScreenShareMessageParser()
            parser.append(frame)
            for _ in 0..<8 { _ = parser.next() }
        }
    }

    static func sampleTCPMessages() -> [ScreenShareMessage] {
        let annotation = Annotation(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF") ?? UUID(),
            tool: .pen,
            points: [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.25)],
            color: Annotation.defaultColor,
            width: Annotation.defaultWidth)
        return [
            .annotation(.add(annotation)),
            .requestToShare(fromHostname: "fuzz-host"),
            .shareResponse(accepted: true),
            .controlRequest,
            .controlGranted,
            .controlRevoked(reason: "fuzz"),
            .inputEvent(.mouseMove(x: 0.5, y: 0.5)),
            .inputEvent(.keyDown(keyCode: 36, modifiers: 0)),
            .controlReleased
        ]
    }

    // MARK: - Target: RTP depacketizers (via MultiCodecDepacketizer)

    /// Build a small valid H.264 + HEVC packet stream (one keyframe-ish NAL
    /// per frame, FU fragmentation included) for mutation strategies.
    private static func validVideoPackets(seed: UInt64) -> [Data] {
        var rng = SeededRNG(seed: seed)
        var packets: [Data] = []
        let h264 = H264Packetizer()
        let h265 = H265Packetizer()
        var seq = UInt16.random(in: 0...UInt16.max, using: &rng)
        for frame in 0..<6 {
            let big = frame % 2 == 0
            let size = big ? 3000 : 100
            var nal = Data([frame % 3 == 0 ? 0x65 : 0x41])
            nal.append(contentsOf: (0..<size).map { UInt8(($0 &+ frame) & 0xFF) })
            let out = h264.packetize(
                nals: [nal], timestamp: UInt32(frame + 1) &* 3000, ssrc: 0x1111, startSequence: seq)
            seq &+= UInt16(out.count)
            packets.append(contentsOf: out)
        }
        var seq265 = UInt16.random(in: 0...UInt16.max, using: &rng)
        for frame in 0..<6 {
            let size = frame % 2 == 0 ? 3000 : 100
            var nal = Data([UInt8(frame % 3 == 0 ? 19 : 1) << 1, 0x01])
            nal.append(contentsOf: (0..<size).map { UInt8(($0 &+ frame) & 0xFF) })
            let out = h265.packetize(
                nals: [nal], timestamp: UInt32(frame + 1) &* 3000, ssrc: 0x2222, startSequence: seq265)
            seq265 &+= UInt16(out.count)
            packets.append(contentsOf: out)
        }
        return packets
    }

    /// Every AU the depacketizer emits must walk cleanly through
    /// `AVCCParser.nalUnits` — terminating, and consuming no more bytes than
    /// the AU holds.
    private func assertAUsSane(_ aus: [VideoAccessUnit], context: String) {
        for au in aus {
            let nals = AVCCParser.nalUnits(from: au.avcc)
            let totalNALBytes = nals.reduce(0) { $0 + $1.count + 4 }
            XCTAssertLessThanOrEqual(
                totalNALBytes, au.avcc.count,
                "\(context): AVCC walk consumed more bytes than the AU holds")
        }
    }

    func fuzzDepacketizerRandomBytes() {
        for i in 0..<(600 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            let depacketizer = MultiCodecDepacketizer()
            var emitted: [VideoAccessUnit] = []
            for _ in 0..<20 {
                let packet = randomData(count: Int.random(in: 0...1500, using: &rng), using: &rng)
                if let au = depacketizer.ingest(packet) { emitted.append(au) }
            }
            assertAUsSane(emitted, context: "random-bytes seed=\(caseSeed)")
        }
    }

    func fuzzDepacketizerBitFlips() {
        for i in 0..<(60 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            var packets = Self.validVideoPackets(seed: caseSeed)
            // Flip 1–3 bits in a handful of random packets.
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let pidx = Int.random(in: 0..<packets.count, using: &rng)
                var packet = packets[pidx]
                guard !packet.isEmpty else { continue }
                let bytePos = Int.random(in: 0..<packet.count, using: &rng)
                packet[packet.startIndex + bytePos] ^= UInt8(1) << Int.random(in: 0..<8, using: &rng)
                packets[pidx] = packet
            }
            let h264 = H264Depacketizer()
            let h265 = H265Depacketizer()
            var emitted: [VideoAccessUnit] = []
            for packet in packets {
                if let au = h264.ingest(packet) { emitted.append(au) }
                if let au = h265.ingest(packet) { emitted.append(au) }
            }
            emitted.append(contentsOf: h264.drainReady())
            emitted.append(contentsOf: h265.drainReady())
            assertAUsSane(emitted, context: "bit-flip seed=\(caseSeed)")
        }
    }

    func fuzzDepacketizerTruncations() {
        let packets = Self.validVideoPackets(seed: baseSeed)
        let depacketizer = MultiCodecDepacketizer()
        var emitted: [VideoAccessUnit] = []
        for (i, packet) in packets.enumerated() {
            // Every 3rd packet arrives truncated at a rotating cut point.
            if i % 3 == 0 {
                let cut = (i / 3) % max(1, packet.count)
                if let au = depacketizer.ingest(Data(packet.prefix(cut))) { emitted.append(au) }
            }
            if let au = depacketizer.ingest(packet) { emitted.append(au) }
        }
        assertAUsSane(emitted, context: "truncation")
        // A 10k-packet duplicate storm must not grow the ready queue without
        // bound — duplicates of one packet can complete at most one AU.
        let storm = packets[0]
        var stormEmitted = 0
        for _ in 0..<10_000 where depacketizer.ingest(storm) != nil {
            stormEmitted += 1
        }
        XCTAssertLessThanOrEqual(stormEmitted, 2, "duplicate storm must not multiply AUs")
    }

    // MARK: - Target: RTPHeader.decode

    func fuzzRTPHeaderDecode() {
        for i in 0..<(2000 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            var data = randomData(count: Int.random(in: 0...64, using: &rng), using: &rng)
            // Half the time, force a plausible V=2 first byte with lying
            // CSRC counts / extension flags so the skip arithmetic runs.
            if !data.isEmpty, Bool.random(using: &rng) {
                data[data.startIndex] = 0x80 | UInt8.random(in: 0...0x3F, using: &rng)
            }
            if let (_, payloadOffset) = RTPHeader.decode(from: data) {
                XCTAssertLessThanOrEqual(
                    payloadOffset, data.count,
                    "payloadOffset must stay within the packet (seed=\(caseSeed))")
            }
            // Slice form: same input re-based must behave identically.
            let padded = Data([0xEE]) + data
            let slice = padded.dropFirst()
            XCTAssertEqual(
                RTPHeader.decode(from: slice)?.payloadOffset,
                RTPHeader.decode(from: data)?.payloadOffset,
                "slice vs zero-based Data must decode identically (seed=\(caseSeed))")
        }
    }

    // MARK: - Target: UDP control decoders

    func fuzzUDPControlDecoders() {
        for i in 0..<(2000 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            let data = randomData(count: Int.random(in: 0...64, using: &rng), using: &rng)
            exerciseUDPDecoders(data)
            // Re-based slice of the same bytes: decoders must be slice-safe.
            let padded = Data([0x00]) + data
            exerciseUDPDecoders(padded.dropFirst())
        }
        fuzzUDPControlTruncationsAndRoundTrips()
    }

    private func exerciseUDPDecoders(_ data: Data) {
        _ = ScreenShareControlMessage.decode(data)
        _ = ScreenShareControlMessage.decodeHelloAck(data)
        _ = ScreenShareControlMessage.decodeHelloCaps(data)
        _ = ScreenShareControlMessage.decodeHelloAckCaps(data)
        _ = ScreenShareControlMessage.decodeNACK(data)
        _ = ScreenShareControlMessage.decodeReceiverReport(data)
        _ = ScreenShareControlMessage.decodePing(data)
    }

    private func fuzzUDPControlTruncationsAndRoundTrips() {
        let report = ReceiverReport(
            fracLostQ8: 42, extHighestSeq: 0x0001_FFFE, jitterTicks: 7,
            lastPingTs: 0x1122_3344_5566_7788, delaySincePingMs: 250)
        let encodes: [Data] = [
            ScreenShareControlMessage.encodeHelloAck(ssrc: 0xCAFE_F00D),
            ScreenShareControlMessage.encodeHelloAck(ssrc: 0xCAFE_F00D, caps: [.nack]),
            ScreenShareControlMessage.encodeHello(caps: [.nack, .receiverReport]),
            ScreenShareControlMessage.encodeNACK([(pid: 100, blp: 0x8001), (pid: 65535, blp: 1)]),
            ScreenShareControlMessage.encodeReceiverReport(report),
            ScreenShareControlMessage.encodePing(serverUptimeNs: 0xDEAD_BEEF_0000_0001)
        ]
        for encoded in encodes {
            for cut in 0..<encoded.count {
                exerciseUDPDecoders(encoded.prefix(cut))
            }
        }
        // Unmutated round-trips must hold exactly.
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloAck(encodes[0]), 0xCAFE_F00D)
        let ackCaps = ScreenShareControlMessage.decodeHelloAckCaps(encodes[1])
        XCTAssertEqual(ackCaps?.ssrc, 0xCAFE_F00D)
        XCTAssertEqual(ackCaps?.caps, [.nack])
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloCaps(encodes[2]), [.nack, .receiverReport])
        let nackEntries = ScreenShareControlMessage.decodeNACK(encodes[3])
        XCTAssertEqual(nackEntries.count, 2)
        XCTAssertEqual(nackEntries.first?.pid, 100)
        XCTAssertEqual(nackEntries.first?.blp, 0x8001)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(encodes[4]), report)
        XCTAssertEqual(ScreenShareControlMessage.decodePing(encodes[5]), 0xDEAD_BEEF_0000_0001)
    }

    // MARK: - Target: AudioRTPDepacketizer

    func fuzzAudioDepacketizer() {
        let unpacker = AudioRTPDepacketizer()
        for i in 0..<(2000 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            let data = randomData(count: Int.random(in: 0...256, using: &rng), using: &rng)
            _ = unpacker.unpack(data)
            _ = unpacker.unpack((Data([0x77]) + data).dropFirst())
        }
        // PT gate: video payload types must be rejected, audio ones accepted.
        for (pt, accepted) in [(96, false), (97, false), (98, true), (99, true)] {
            var packet = Data()
            let header = RTPHeader(
                marker: true, payloadType: UInt8(pt), sequenceNumber: 5, timestamp: 1024, ssrc: 3)
            header.encode(into: &packet)
            packet.append(contentsOf: [0x01, 0x02, 0x03])
            if accepted {
                XCTAssertNotNil(unpacker.unpack(packet), "PT \(pt) is audio and must unpack")
            } else {
                XCTAssertNil(unpacker.unpack(packet), "PT \(pt) is video and must be rejected")
            }
        }
    }

    // MARK: - Target: decodeParameterSets (helper wire)

    /// Build a valid `parameterSets` payload matching
    /// `HelperFrameWriter.writeParameterSets`' layout.
    static func validParameterSetsPayload(codec: UInt8, paramSets: [Data]) -> Data {
        var payload = Data()
        payload.append(codec)
        for dim: UInt32 in [1920, 1080, UInt32(paramSets.count)] {
            payload.append(UInt8((dim >> 24) & 0xFF))
            payload.append(UInt8((dim >> 16) & 0xFF))
            payload.append(UInt8((dim >> 8) & 0xFF))
            payload.append(UInt8(dim & 0xFF))
        }
        for ps in paramSets {
            let len = UInt32(ps.count)
            payload.append(UInt8((len >> 24) & 0xFF))
            payload.append(UInt8((len >> 16) & 0xFF))
            payload.append(UInt8((len >> 8) & 0xFF))
            payload.append(UInt8(len & 0xFF))
            payload.append(ps)
        }
        return payload
    }

    func fuzzDecodeParameterSets() {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let vps = Data([0x40, 0x01, 0x0C])
        let valid = Self.validParameterSetsPayload(codec: 0, paramSets: [sps, pps])
        let validHEVC = Self.validParameterSetsPayload(codec: 1, paramSets: [vps, sps, pps])

        // Unmutated parses — both zero-based and as a re-based slice. This is
        // the case that pinned the absolute-offset readBE32 hazard: the old
        // implementation trapped on any Data slice with a non-zero startIndex.
        XCTAssertNotNil(HelperScreenCapture.decodeParameterSets(valid))
        XCTAssertNotNil(HelperScreenCapture.decodeParameterSets(validHEVC))
        let paddedValid = Data([0xFF, 0xFF]) + valid
        XCTAssertNotNil(
            HelperScreenCapture.decodeParameterSets(paddedValid.dropFirst(2)),
            "decodeParameterSets must accept a re-based Data slice")

        // Truncations: every strict prefix cleanly rejects (or parses a
        // shorter-but-consistent set) without crashing.
        for source in [valid, validHEVC] {
            for cut in 0..<source.count {
                _ = HelperScreenCapture.decodeParameterSets(source.prefix(cut))
                let padded = Data([0xAB]) + source.prefix(cut)
                _ = HelperScreenCapture.decodeParameterSets(padded.dropFirst())
            }
        }

        // Random bytes + bit flips + length-field mutations.
        for i in 0..<(800 * multiplier) {
            let caseSeed = seed(i)
            var rng = SeededRNG(seed: caseSeed)
            switch i % 3 {
            case 0:
                let data = randomData(count: Int.random(in: 0...128, using: &rng), using: &rng)
                _ = HelperScreenCapture.decodeParameterSets(data)
                _ = HelperScreenCapture.decodeParameterSets((Data([0x00]) + data).dropFirst())
            case 1:
                var mutated = valid
                let bytePos = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[mutated.startIndex + bytePos] ^= UInt8(1) << Int.random(in: 0..<8, using: &rng)
                _ = HelperScreenCapture.decodeParameterSets(mutated)
                _ = HelperScreenCapture.decodeParameterSets((Data([0x00]) + mutated).dropFirst())
            default:
                // Patch the per-set length field to hostile values.
                var mutated = validHEVC
                let lenFieldOffset = 13
                let hostile = UInt32.random(in: 0...UInt32.max, using: &rng)
                mutated[mutated.startIndex + lenFieldOffset] = UInt8((hostile >> 24) & 0xFF)
                mutated[mutated.startIndex + lenFieldOffset + 1] = UInt8((hostile >> 16) & 0xFF)
                mutated[mutated.startIndex + lenFieldOffset + 2] = UInt8((hostile >> 8) & 0xFF)
                mutated[mutated.startIndex + lenFieldOffset + 3] = UInt8(hostile & 0xFF)
                _ = HelperScreenCapture.decodeParameterSets(mutated)
            }
        }
    }

    /// Run everything — the nightly soak entry point.
    func runAll() {
        fuzzTCPParserRandomBytes()
        fuzzTCPParserTruncations()
        fuzzTCPParserPayloadBitFlips()
        fuzzTCPParserLengthMutations()
        fuzzDepacketizerRandomBytes()
        fuzzDepacketizerBitFlips()
        fuzzDepacketizerTruncations()
        fuzzRTPHeaderDecode()
        fuzzUDPControlDecoders()
        fuzzAudioDepacketizer()
        fuzzDecodeParameterSets()
    }
}

/// PR-budget runs of the fuzz harness (multiplier 1, seconds total). The
/// nightly soak (`SoakTests`, env-gated) runs the same code at ~50×.
final class ParserFuzzTests: XCTestCase {
    private let harness = ParserFuzzHarness()

    func testTCPParserRandomBytes() { harness.fuzzTCPParserRandomBytes() }
    func testTCPParserTruncations() { harness.fuzzTCPParserTruncations() }
    func testTCPParserPayloadBitFlips() { harness.fuzzTCPParserPayloadBitFlips() }
    func testTCPParserLengthMutations() { harness.fuzzTCPParserLengthMutations() }
    func testDepacketizerRandomBytes() { harness.fuzzDepacketizerRandomBytes() }
    func testDepacketizerBitFlips() { harness.fuzzDepacketizerBitFlips() }
    func testDepacketizerTruncations() { harness.fuzzDepacketizerTruncations() }
    func testRTPHeaderDecode() { harness.fuzzRTPHeaderDecode() }
    func testUDPControlDecoders() { harness.fuzzUDPControlDecoders() }
    func testAudioDepacketizer() { harness.fuzzAudioDepacketizer() }
    func testDecodeParameterSets() { harness.fuzzDecodeParameterSets() }
}
