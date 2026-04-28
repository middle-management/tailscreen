import XCTest
@testable import Tailscreen

final class RTPAudioTests: XCTestCase {
    func testRoundtripSingleAU() throws {
        let pack = AudioRTPPacketizer(ssrc: 0xCAFEBABE)
        let depack = AudioRTPDepacketizer()
        let au = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])

        let packet = pack.packetize(au: au)
        let parsed = depack.unpack(packet)

        XCTAssertEqual(parsed?.ssrc, 0xCAFEBABE)
        XCTAssertEqual(parsed?.au, au)
        XCTAssertEqual(parsed?.payloadType, 98)
    }

    func testTimestampIncrementsBy1024PerAU() {
        let pack = AudioRTPPacketizer(ssrc: 1)
        let au = Data([0x00])

        let p1 = pack.packetize(au: au)
        let p2 = pack.packetize(au: au)

        let ts1 = RTPHeader.decode(from: p1)?.header.timestamp
        let ts2 = RTPHeader.decode(from: p2)?.header.timestamp
        XCTAssertNotNil(ts1)
        XCTAssertNotNil(ts2)
        XCTAssertEqual(ts2! &- ts1!, 1024)
    }

    func testSequenceWraparound() {
        let pack = AudioRTPPacketizer(ssrc: 1, startSequence: 0xFFFF)
        let au = Data([0x00])

        let p1 = pack.packetize(au: au)
        let p2 = pack.packetize(au: au)

        XCTAssertEqual(RTPHeader.decode(from: p1)?.header.sequenceNumber, 0xFFFF)
        XCTAssertEqual(RTPHeader.decode(from: p2)?.header.sequenceNumber, 0x0000)
    }

    func testDepackRejectsNonAudioPayloadType() {
        // Build an RTP packet with PT=96 (H.264), feed to audio depack.
        var data = Data()
        let header = RTPHeader(
            marker: false,
            payloadType: RTPHeader.h264PayloadType,
            sequenceNumber: 0,
            timestamp: 0,
            ssrc: 1
        )
        header.encode(into: &data)
        data.append(contentsOf: [0xAA, 0xBB])

        let depack = AudioRTPDepacketizer()
        XCTAssertNil(depack.unpack(data))
    }
}
