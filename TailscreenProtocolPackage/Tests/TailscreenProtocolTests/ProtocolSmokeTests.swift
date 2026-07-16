import XCTest

@testable import TailscreenProtocol

/// Smoke tests proving the TailscreenProtocol module is *usable* on Linux —
/// encode/decode actually runs, not merely compiles. Deliberately shallow:
/// the exhaustive wire-format, loss-recovery, and fuzz coverage lives in the
/// main repo's `Tests/TailscreenTests`, which compiles these same sources as
/// part of the Tailscreen target. Keep this file to a handful of round trips.
final class ProtocolSmokeTests: XCTestCase {
    func testRTPHeaderRoundTrip() {
        let header = RTPHeader(
            marker: true,
            payloadType: RTPHeader.hevcPayloadType,
            sequenceNumber: 0xBEEF,
            timestamp: 123_456_789,
            ssrc: 42
        )
        var wire = Data()
        header.encode(into: &wire)
        wire.append(contentsOf: [0x01, 0x02, 0x03])  // payload

        guard let (decoded, payloadOffset) = RTPHeader.decode(from: wire) else {
            XCTFail("decode failed")
            return
        }
        XCTAssertEqual(decoded.marker, header.marker)
        XCTAssertEqual(decoded.payloadType, header.payloadType)
        XCTAssertEqual(decoded.sequenceNumber, header.sequenceNumber)
        XCTAssertEqual(decoded.timestamp, header.timestamp)
        XCTAssertEqual(decoded.ssrc, header.ssrc)
        XCTAssertEqual(payloadOffset, RTPHeader.size)
    }

    func testFramedMessageRoundTrip() {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.shareResponse(accepted: true).encode())
        parser.append(ScreenShareMessage.controlRequest.encode())

        guard case .shareResponse(let accepted)? = parser.next() else {
            XCTFail("expected .shareResponse")
            return
        }
        XCTAssertTrue(accepted)
        guard case .controlRequest? = parser.next() else {
            XCTFail("expected .controlRequest")
            return
        }
        XCTAssertNil(parser.next())
        XCTAssertFalse(parser.isCorrupt)
    }

    func testOversizedFramePoisonsParser() {
        var poison = Data()
        poison.append(ScreenShareMessage.MessageType.annotation.rawValue)
        let badLength = UInt32(ScreenShareMessage.maxPayloadLength + 1)
        poison.append(contentsOf: [
            UInt8((badLength >> 24) & 0xFF), UInt8((badLength >> 16) & 0xFF),
            UInt8((badLength >> 8) & 0xFF), UInt8(badLength & 0xFF)
        ])
        var parser = ScreenShareMessageParser()
        parser.append(poison)
        XCTAssertNil(parser.next())
        XCTAssertTrue(parser.isCorrupt)
    }

    func testFECRecoversSingleLoss() {
        let ssrc: UInt32 = 7
        var packets: [Data] = []
        for seq in 0..<3 {
            var packet = Data()
            let header = RTPHeader(
                marker: seq == 2,
                payloadType: RTPHeader.h264PayloadType,
                sequenceNumber: UInt16(100 + seq),
                timestamp: 9000,
                ssrc: ssrc
            )
            header.encode(into: &packet)
            packet.append(Data(repeating: UInt8(seq + 1), count: 10 + seq))
            packets.append(packet)
        }
        let parity = FECCodec.parityBody(for: packets[...])
        XCTAssertFalse(parity.isEmpty)

        let recovered = FECCodec.recover(
            missingSeq: 101,
            ssrc: ssrc,
            members: [packets[0], packets[2]],
            body: parity
        )
        XCTAssertEqual(recovered, packets[1])
    }

    func testInputEventJSONRoundTrip() throws {
        let events: [InputEvent] = [
            .mouseDown(x: 0.1, y: 0.9, button: .middle, modifiers: [.meta, .shift]),
            .scroll(x: 0.5, y: 0.5, deltaX: -2, deltaY: 3, modifiers: [.shift]),
            .keyDown(key: 0x28, modifiers: [.control]),
            .keyUp(key: 0x28, modifiers: [])
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(InputEvent.self, from: data), event)
        }
    }

    func testMacKeyCodeTableIsBijective() {
        let forward = MacKeyCodeMapping.hidUsageByMacKeyCode
        XCTAssertEqual(Set(forward.values).count, forward.count)
        for (mac, hid) in forward {
            XCTAssertEqual(MacKeyCodeMapping.macKeyCode(forHIDUsage: hid), mac)
        }
        // Spot rows: Return→Enter, ⌘→GUI, A→A.
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x24), 0x28)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x37), 0xE3)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x00), 0x04)
    }

    func testHelloAckCapsRoundTrip() {
        let caps: ScreenShareCaps = [.nack, .receiverReport, .fec]
        let wire = ScreenShareControlMessage.encodeHelloAck(ssrc: 0xDEAD_BEEF, caps: caps)
        guard let (ssrc, decodedCaps) = ScreenShareControlMessage.decodeHelloAckCaps(wire) else {
            XCTFail("decodeHelloAckCaps failed")
            return
        }
        XCTAssertEqual(ssrc, 0xDEAD_BEEF)
        XCTAssertEqual(decodedCaps, caps)
        // Legacy strict decoder must reject the extended 6-byte form — that
        // back-compat contract is what keeps old viewers PLI-only.
        XCTAssertNil(ScreenShareControlMessage.decodeHelloAck(wire))
    }
}
