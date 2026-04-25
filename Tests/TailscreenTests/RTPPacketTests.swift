import XCTest
@testable import Tailscreen

final class RTPPacketTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        var buffer = Data()
        let original = RTPHeader(
            marker: true,
            payloadType: 96,
            sequenceNumber: 0xABCD,
            timestamp: 0x1234_5678,
            ssrc: 0xDEAD_BEEF
        )
        original.encode(into: &buffer)

        XCTAssertEqual(buffer.count, RTPHeader.size)

        let (decoded, payloadOffset) = try XCTUnwrap(RTPHeader.decode(from: buffer))
        XCTAssertEqual(payloadOffset, RTPHeader.size)
        XCTAssertTrue(decoded.marker)
        XCTAssertEqual(decoded.payloadType, 96)
        XCTAssertEqual(decoded.sequenceNumber, 0xABCD)
        XCTAssertEqual(decoded.timestamp, 0x1234_5678)
        XCTAssertEqual(decoded.ssrc, 0xDEAD_BEEF)
    }

    func testHeaderRejectsWrongVersion() {
        var buffer = Data([0x40, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])  // V=1
        XCTAssertNil(RTPHeader.decode(from: buffer))
        buffer[0] = 0x80
        XCTAssertNotNil(RTPHeader.decode(from: buffer))
    }

    func testControlPacketsAreDistinguishable() {
        let hello = ScreenShareControlMessage.encode(.hello)
        let pli = ScreenShareControlMessage.encode(.pli)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(hello))
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(pli))
        XCTAssertEqual(ScreenShareControlMessage.decode(hello), .hello)
        XCTAssertEqual(ScreenShareControlMessage.decode(pli), .pli)

        // A real RTP packet's first byte is 0x80; must not look like control.
        var rtp = Data()
        RTPHeader(marker: false, payloadType: 96, sequenceNumber: 0, timestamp: 0, ssrc: 1).encode(into: &rtp)
        XCTAssertFalse(ScreenShareControlMessage.looksLikeControl(rtp))
    }

    func testAVCCParserSplitsLengthPrefixedNALs() {
        let nal1 = Data([0x67, 0xAA, 0xBB])           // SPS
        let nal2 = Data([0x68, 0xCC])                  // PPS
        let nal3 = Data([0x65] + Array(repeating: UInt8(0x99), count: 100))  // IDR slice

        var avcc = Data()
        for nal in [nal1, nal2, nal3] {
            avcc.appendBE(UInt32(nal.count))
            avcc.append(nal)
        }

        let parsed = AVCCParser.nalUnits(from: avcc)
        XCTAssertEqual(parsed, [nal1, nal2, nal3])
    }

    func testSingleNALPacketization() throws {
        // Small NAL fits in one Single NAL packet.
        let nal = Data([0x67, 0x42, 0x00, 0x1F, 0xAC])  // SPS
        let packets = H264Packetizer.packetize(
            nals: [nal], timestamp: 9000, ssrc: 0x11_22_33_44, startSequence: 100
        )

        XCTAssertEqual(packets.count, 1)
        let packet = packets[0]
        let (header, offset) = try XCTUnwrap(RTPHeader.decode(from: packet))
        XCTAssertTrue(header.marker)  // last (and only) packet of AU
        XCTAssertEqual(header.sequenceNumber, 100)
        XCTAssertEqual(header.timestamp, 9000)
        XCTAssertEqual(packet.suffix(from: packet.startIndex + offset), nal)
    }

    func testFragmentedNALPacketization() throws {
        // Build a NAL larger than maxPayloadBytes to force FU-A.
        let bodySize = H264Packetizer.maxPayloadBytes * 3 - 7
        var nal = Data([0x65])  // IDR slice header (NRI=11, type=5)
        nal.append(contentsOf: (0..<bodySize).map { UInt8($0 & 0xFF) })

        let packets = H264Packetizer.packetize(
            nals: [nal], timestamp: 18000, ssrc: 1, startSequence: 0
        )

        // Body is split into ceil(bodySize / (maxPayload-2)) fragments.
        let fragSize = H264Packetizer.maxPayloadBytes - 2
        let expectedFragments = (bodySize + fragSize - 1) / fragSize
        XCTAssertEqual(packets.count, expectedFragments)

        for (i, packet) in packets.enumerated() {
            let (header, offset) = try XCTUnwrap(RTPHeader.decode(from: packet))
            XCTAssertEqual(header.timestamp, 18000)
            XCTAssertEqual(header.sequenceNumber, UInt16(i))
            XCTAssertEqual(header.marker, i == packets.count - 1)

            let payload = packet.suffix(from: packet.startIndex + offset)
            XCTAssertGreaterThanOrEqual(payload.count, 3)
            let fuIndicator = payload[payload.startIndex]
            let fuHeader = payload[payload.startIndex + 1]
            XCTAssertEqual(fuIndicator & 0x1F, 28)               // type 28 = FU-A
            XCTAssertEqual(fuIndicator & 0xE0, 0x60)             // NRI preserved (0x65 → NRI=11)
            XCTAssertEqual(fuHeader & 0x1F, 5)                   // original NAL type
            XCTAssertEqual((fuHeader & 0x80) != 0, i == 0)       // S bit on first
            XCTAssertEqual((fuHeader & 0x40) != 0, i == packets.count - 1)  // E bit on last
        }
    }

    func testSingleNALRoundTripThroughDepacketizer() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCB, 0x83])
        let slice = Data([0x65, 0xAA, 0xBB, 0xCC, 0xDD])  // small IDR slice

        let packets = H264Packetizer.packetize(
            nals: [sps, pps, slice], timestamp: 12345, ssrc: 0xCAFE, startSequence: 7
        )
        XCTAssertEqual(packets.count, 3)

        let depacketizer = H264Depacketizer()
        var au: H264Depacketizer.AccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)

        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertEqual(unwrapped.timestamp, 12345)
        XCTAssertFalse(unwrapped.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [sps, pps, slice])
    }

    func testFragmentedNALRoundTripThroughDepacketizer() throws {
        // Mix small + large NALs in one access unit to exercise both modes.
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let bodySize = H264Packetizer.maxPayloadBytes * 2 + 137
        var slice = Data([0x65])
        slice.append(contentsOf: (0..<bodySize).map { UInt8(($0 * 13) & 0xFF) })

        let packets = H264Packetizer.packetize(
            nals: [sps, slice], timestamp: 90_000, ssrc: 1, startSequence: 0xFFFE
        )

        let depacketizer = H264Depacketizer()
        var au: H264Depacketizer.AccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)

        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertFalse(unwrapped.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [sps, slice])
    }

    func testSequenceWraparoundIsAccepted() throws {
        // First packet seq = 0xFFFF, second seq = 0x0000. The depacketizer
        // must treat the wraparound as in-sequence (not as packet loss).
        let nal1 = Data([0x41, 0xAA])
        let nal2 = Data([0x41, 0xBB])

        var p1Packets = H264Packetizer.packetize(
            nals: [nal1], timestamp: 1, ssrc: 1, startSequence: 0xFFFF
        )
        // Packetizer puts marker on the last packet of the AU it's given,
        // which is what we want here — that flushes AU1.
        let p2Packets = H264Packetizer.packetize(
            nals: [nal2], timestamp: 2, ssrc: 1, startSequence: 0x0000
        )
        p1Packets.append(contentsOf: p2Packets)

        let depacketizer = H264Depacketizer()
        var aus: [H264Depacketizer.AccessUnit] = []
        for p in p1Packets {
            if let result = depacketizer.ingest(p) { aus.append(result) }
        }

        XCTAssertEqual(aus.count, 2)
        XCTAssertFalse(aus[0].lostBeforeThisAU)
        XCTAssertFalse(aus[1].lostBeforeThisAU)
    }

    func testDroppedPacketCorruptsAUAndSignalsLoss() {
        let nal1 = Data([0x41, 0xAA])
        let nal2 = Data([0x41, 0xBB])
        let nal3 = Data([0x41, 0xCC])

        let packets = H264Packetizer.packetize(
            nals: [nal1, nal2, nal3], timestamp: 50, ssrc: 1, startSequence: 10
        )
        XCTAssertEqual(packets.count, 3)

        // Drop the middle packet.
        let depacketizer = H264Depacketizer()
        _ = depacketizer.ingest(packets[0])
        let result = depacketizer.ingest(packets[2])

        // AU is dropped (returns nil) because we know it's torn.
        XCTAssertNil(result)

        // Next AU should still arrive cleanly, but flagged as lost-before.
        let nal4 = Data([0x41, 0xDD])
        let next = H264Packetizer.packetize(
            nals: [nal4], timestamp: 60, ssrc: 1, startSequence: 13
        )
        let au = depacketizer.ingest(next[0])
        XCTAssertNotNil(au)
        XCTAssertTrue(au?.lostBeforeThisAU ?? false)
    }

    func testSSRCChangeResetsState() throws {
        let nal = Data([0x41, 0x01])
        let firstSession = H264Packetizer.packetize(
            nals: [nal], timestamp: 1, ssrc: 0xAAAA, startSequence: 50
        )
        // New session (server restart): different SSRC, sequence starts over.
        let secondSession = H264Packetizer.packetize(
            nals: [nal], timestamp: 1, ssrc: 0xBBBB, startSequence: 0
        )

        let depacketizer = H264Depacketizer()
        _ = depacketizer.ingest(firstSession[0])
        // Without SSRC reset, seq=0 after seq=50 would look like a wild
        // jump and the AU would be flagged as lost. SSRC change should
        // wipe state and treat the second session as fresh.
        let au = try XCTUnwrap(depacketizer.ingest(secondSession[0]))
        XCTAssertFalse(au.lostBeforeThisAU)
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
