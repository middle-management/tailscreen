import XCTest
@testable import Cuple

final class ScreenShareProtocolTests: XCTestCase {
    func testRoundTripFrame() throws {
        let payload = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let message: ScreenShareMessage = .frame(data: payload, isKeyframe: true)

        var parser = ScreenShareMessageParser()
        parser.append(message.encode())

        let decoded = try XCTUnwrap(parser.next())
        guard case let .frame(data: got, isKeyframe: key) = decoded else {
            return XCTFail("expected .frame, got \(decoded)")
        }
        XCTAssertEqual(got, payload)
        XCTAssertTrue(key)
        XCTAssertNil(parser.next())
    }

    func testRoundTripParameterSets() throws {
        let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9])
        let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])
        let message: ScreenShareMessage = .parameterSets(sps: sps, pps: pps)

        var parser = ScreenShareMessageParser()
        parser.append(message.encode())

        let decoded = try XCTUnwrap(parser.next())
        guard case let .parameterSets(sps: gotSps, pps: gotPps) = decoded else {
            return XCTFail("expected .parameterSets, got \(decoded)")
        }
        XCTAssertEqual(gotSps, sps)
        XCTAssertEqual(gotPps, pps)
    }

    func testPartialReceiveReturnsNilUntilComplete() {
        let payload = Data(repeating: 0xAB, count: 300)
        let full = ScreenShareMessage.frame(data: payload, isKeyframe: false).encode()

        var parser = ScreenShareMessageParser()

        // Feed half the header — not enough to parse anything.
        parser.append(full.prefix(2))
        XCTAssertNil(parser.next())

        // Finish the header but leave the payload incomplete.
        parser.append(full.subdata(in: 2..<10))
        XCTAssertNil(parser.next())

        // Deliver the remainder.
        parser.append(full.subdata(in: 10..<full.count))
        let decoded = parser.next()
        XCTAssertNotNil(decoded)
        if case let .frame(data: got, isKeyframe: key) = decoded {
            XCTAssertEqual(got, payload)
            XCTAssertFalse(key)
        } else {
            XCTFail("expected .frame")
        }
    }

    func testMultipleMessagesInOneChunk() throws {
        let m1: ScreenShareMessage = .frame(data: Data([1, 2, 3]), isKeyframe: true)
        let m2: ScreenShareMessage = .parameterSets(sps: Data([0x67]), pps: Data([0x68]))
        let m3: ScreenShareMessage = .frame(data: Data([4, 5]), isKeyframe: false)

        var combined = Data()
        combined.append(m1.encode())
        combined.append(m2.encode())
        combined.append(m3.encode())

        var parser = ScreenShareMessageParser()
        parser.append(combined)

        // Three messages come back in order.
        let d1 = try XCTUnwrap(parser.next())
        let d2 = try XCTUnwrap(parser.next())
        let d3 = try XCTUnwrap(parser.next())
        XCTAssertNil(parser.next())

        guard case let .frame(data: got1, isKeyframe: k1) = d1 else { return XCTFail("d1") }
        guard case let .parameterSets(sps: gotSps, pps: gotPps) = d2 else { return XCTFail("d2") }
        guard case let .frame(data: got3, isKeyframe: k3) = d3 else { return XCTFail("d3") }

        XCTAssertEqual(got1, Data([1, 2, 3]))
        XCTAssertTrue(k1)
        XCTAssertEqual(gotSps, Data([0x67]))
        XCTAssertEqual(gotPps, Data([0x68]))
        XCTAssertEqual(got3, Data([4, 5]))
        XCTAssertFalse(k3)
    }

    func testUnknownMessageTypeIsSkipped() throws {
        // Hand-build a bogus message with type=0xFF, then a valid frame after it.
        var bogus = Data()
        bogus.append(0xFF)                               // unknown type
        bogus.append(contentsOf: [0x00, 0x00, 0x00, 0x02])  // payload len = 2, big-endian
        bogus.append(contentsOf: [0xDE, 0xAD])           // payload

        let good = ScreenShareMessage.frame(data: Data([7, 7, 7]), isKeyframe: true).encode()

        var parser = ScreenShareMessageParser()
        parser.append(bogus + good)

        // The unknown message is consumed and the parser returns the next valid one.
        let decoded = try XCTUnwrap(parser.next())
        guard case let .frame(data: got, isKeyframe: _) = decoded else {
            return XCTFail("expected .frame after skipping unknown type")
        }
        XCTAssertEqual(got, Data([7, 7, 7]))
    }

    func testBigEndianLengthField() {
        // Construct a frame whose payload is larger than 255 bytes so we exercise
        // every byte of the length field (not just the last one).
        let payload = Data(repeating: 0x42, count: 500)
        let encoded = ScreenShareMessage.frame(data: payload, isKeyframe: false).encode()

        // Header is [type=0x02][length big-endian]. Payload length is 1 (keyframe) + 500.
        XCTAssertEqual(encoded[0], 0x02)
        let lenBytes = encoded.subdata(in: 1..<5)
        let expectedLen = UInt32(501).bigEndian
        var expected = Data(count: 4)
        _ = expected.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: expectedLen, as: UInt32.self)
        }
        XCTAssertEqual(lenBytes, expected)
    }
}
