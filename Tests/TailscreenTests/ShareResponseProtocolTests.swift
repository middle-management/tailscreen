import XCTest

@testable import Tailscreen

/// Wire-format tests for the `.shareResponse` (0x05) control message that
/// finishes the request-to-share round-trip. CI-able — pure parser, no
/// tsnet. Companion to `ScreenShareProtocolTests`.
final class ShareResponseProtocolTests: XCTestCase {

    /// Hand-build a frame so tests can inject payloads `encode()` would
    /// never produce (garbage, wrong request kind).
    private func frame(type: UInt8, payload: Data) -> Data {
        var data = Data()
        data.append(type)
        let len = UInt32(payload.count)
        data.append(UInt8((len >> 24) & 0xFF))
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))
        data.append(payload)
        return data
    }

    func testShareResponseAcceptRoundTrip() throws {
        let message: ScreenShareMessage = .shareResponse(accepted: true)
        var parser = ScreenShareMessageParser()
        parser.append(message.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .shareResponse(let accepted) = decoded else {
            return XCTFail("expected .shareResponse, got \(decoded)")
        }
        XCTAssertTrue(accepted)
        XCTAssertNil(parser.next())
    }

    func testShareResponseDeclineRoundTrip() throws {
        let message: ScreenShareMessage = .shareResponse(accepted: false)
        var parser = ScreenShareMessageParser()
        parser.append(message.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .shareResponse(let accepted) = decoded else {
            return XCTFail("expected .shareResponse, got \(decoded)")
        }
        XCTAssertFalse(accepted)
    }

    func testUnknownTypeByteStillSkippedBeforeShareResponse() throws {
        // Old-peer compatibility both ways: a parser that doesn't know a
        // type byte consumes and drops the whole frame, then keeps going.
        let bogus = frame(type: 0x7F, payload: Data([0xDE, 0xAD]))
        let good = ScreenShareMessage.shareResponse(accepted: true).encode()

        var parser = ScreenShareMessageParser()
        parser.append(bogus + good)
        let decoded = try XCTUnwrap(parser.next())
        guard case .shareResponse(true) = decoded else {
            return XCTFail("expected .shareResponse(true) after skipping unknown type")
        }
    }

    func testGarbageShareResponsePayloadIsDropped() throws {
        // Undecodable JSON: the frame is consumed (returns nil) and the
        // parser recovers on the next complete frame.
        let garbage = frame(type: 0x05, payload: Data("not json at all".utf8))
        var parser = ScreenShareMessageParser()
        parser.append(garbage)
        XCTAssertNil(parser.next())

        parser.append(ScreenShareMessage.shareResponse(accepted: false).encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .shareResponse(false) = decoded else {
            return XCTFail("expected .shareResponse(false) after dropping garbage frame")
        }
    }

    func testRequestPayloadInsideResponseFrameIsRejected() throws {
        // A `.requestToShare` TailscreenRequest smuggled into a 0x05 frame
        // is malformed — it must decode to nothing, not to a response.
        let payload = try JSONEncoder().encode(TailscreenRequest.requestToShare(from: "mallory"))
        var parser = ScreenShareMessageParser()
        parser.append(frame(type: 0x05, payload: payload))
        XCTAssertNil(parser.next())
    }

    func testShareResponsePayloadIsTailscreenRequestJSON() throws {
        // Pin the wire payload shape: JSON-encoded TailscreenRequest, so
        // the scaffolded .acceptShare/.declineShare cases stay the schema.
        let encoded = ScreenShareMessage.shareResponse(accepted: true).encode()
        XCTAssertEqual(encoded.first, ScreenShareMessage.MessageType.shareResponse.rawValue)
        let payload = encoded.dropFirst(ScreenShareMessage.headerSize)
        let request = try JSONDecoder().decode(TailscreenRequest.self, from: Data(payload))
        guard case .acceptShare = request else {
            return XCTFail("expected .acceptShare payload, got \(request)")
        }
    }
}
