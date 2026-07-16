import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

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

        guard let ts1 = RTPHeader.decode(from: p1)?.header.timestamp,
            let ts2 = RTPHeader.decode(from: p2)?.header.timestamp
        else {
            XCTFail("RTPHeader.decode returned nil")
            return
        }
        XCTAssertEqual(ts2 &- ts1, 1024)
    }

    func testSequenceWraparound() {
        let pack = AudioRTPPacketizer(ssrc: 1, startSequence: 0xFFFF)
        let au = Data([0x00])

        let p1 = pack.packetize(au: au)
        let p2 = pack.packetize(au: au)

        XCTAssertEqual(RTPHeader.decode(from: p1)?.header.sequenceNumber, 0xFFFF)
        XCTAssertEqual(RTPHeader.decode(from: p2)?.header.sequenceNumber, 0x0000)
    }

    func testSystemAudioPacketizerStampsPT99AndSSRC1() throws {
        let pack = AudioRTPPacketizer(
            ssrc: RTPHeader.systemAudioSSRC, payloadType: RTPHeader.systemAudioPayloadType)
        let au = Data([0x11, 0x22, 0x33])
        let parsed = AudioRTPDepacketizer().unpack(pack.packetize(au: au))
        XCTAssertEqual(parsed?.ssrc, 1)
        XCTAssertEqual(parsed?.payloadType, 99)
        XCTAssertEqual(parsed?.au, au)
    }

    func testDefaultPacketizerStampsVoicePT98() {
        let pack = AudioRTPPacketizer(ssrc: 7)
        let parsed = AudioRTPDepacketizer().unpack(pack.packetize(au: Data([0x01])))
        XCTAssertEqual(parsed?.payloadType, 98)
    }

    func testDepackAcceptsBothAudioPayloadTypes() {
        for pt in [RTPHeader.aacPayloadType, RTPHeader.systemAudioPayloadType] {
            var data = Data()
            let header = RTPHeader(
                marker: true, payloadType: pt, sequenceNumber: 1, timestamp: 0, ssrc: 3)
            header.encode(into: &data)
            data.append(contentsOf: [0xAA, 0xBB])
            let parsed = AudioRTPDepacketizer().unpack(data)
            XCTAssertEqual(parsed?.payloadType, pt)
        }
    }

    func testDepackStillRejectsVideoPayloadTypes() {
        for pt in [RTPHeader.h264PayloadType, RTPHeader.hevcPayloadType] {
            var data = Data()
            let header = RTPHeader(
                marker: false, payloadType: pt, sequenceNumber: 0, timestamp: 0, ssrc: 1)
            header.encode(into: &data)
            data.append(0xCC)
            XCTAssertNil(AudioRTPDepacketizer().unpack(data))
        }
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
