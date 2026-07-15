import XCTest

@testable import Tailscreen

final class ScreenShareProtocolTests: XCTestCase {
    func testRoundTripAnnotation() throws {
        let ann = Annotation(
            id: UUID(),
            tool: .arrow,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)],
            color: Annotation.defaultColor,
            width: Annotation.defaultWidth
        )
        let op = AnnotationOp.add(ann)
        let message: ScreenShareMessage = .annotation(op)

        var parser = ScreenShareMessageParser()
        parser.append(message.encode())

        let decoded = try XCTUnwrap(parser.next())
        guard case .annotation(let gotOp) = decoded else {
            return XCTFail("expected .annotation, got \(decoded)")
        }
        XCTAssertEqual(gotOp, op)
        XCTAssertNil(parser.next())
    }

    func testAnnotationClearAllRoundTrip() throws {
        let message: ScreenShareMessage = .annotation(.clearAll)
        var parser = ScreenShareMessageParser()
        parser.append(message.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .annotation(.clearAll) = decoded else {
            return XCTFail("expected .annotation(.clearAll), got \(decoded)")
        }
    }

    func testAnnotationUndoRoundTrip() throws {
        let id = UUID()
        let message: ScreenShareMessage = .annotation(.undo(id))
        var parser = ScreenShareMessageParser()
        parser.append(message.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .annotation(.undo(let gotId)) = decoded else {
            return XCTFail("expected .annotation(.undo), got \(decoded)")
        }
        XCTAssertEqual(gotId, id)
    }

    func testPartialReceiveReturnsNilUntilComplete() {
        let op = AnnotationOp.add(
            Annotation(
                id: UUID(), tool: .pen,
                points: [CGPoint(x: 0.5, y: 0.5)],
                color: Annotation.defaultColor, width: 2
            ))
        let full = ScreenShareMessage.annotation(op).encode()

        var parser = ScreenShareMessageParser()
        // Half the header — not enough to parse anything.
        parser.append(full.prefix(2))
        XCTAssertNil(parser.next())
        // Header complete but payload truncated.
        parser.append(full.subdata(in: 2..<min(10, full.count)))
        XCTAssertNil(parser.next())
        // Deliver the rest.
        if full.count > 10 {
            parser.append(full.subdata(in: 10..<full.count))
        }
        XCTAssertNotNil(parser.next())
    }

    func testMultipleMessagesInOneChunk() throws {
        let id1 = UUID()
        let id2 = UUID()
        let m1 = ScreenShareMessage.annotation(.undo(id1)).encode()
        let m2 = ScreenShareMessage.annotation(.clearAll).encode()
        let m3 = ScreenShareMessage.annotation(.undo(id2)).encode()

        var parser = ScreenShareMessageParser()
        parser.append(m1 + m2 + m3)

        let d1 = try XCTUnwrap(parser.next())
        let d2 = try XCTUnwrap(parser.next())
        let d3 = try XCTUnwrap(parser.next())
        XCTAssertNil(parser.next())

        guard case .annotation(.undo(let got1)) = d1 else { return XCTFail("d1") }
        guard case .annotation(.clearAll) = d2 else { return XCTFail("d2") }
        guard case .annotation(.undo(let got3)) = d3 else { return XCTFail("d3") }
        XCTAssertEqual(got1, id1)
        XCTAssertEqual(got3, id2)
    }

    func testRequestToShareRoundTrip() throws {
        let message: ScreenShareMessage = .requestToShare(fromHostname: "wisp-1")
        var parser = ScreenShareMessageParser()
        parser.append(message.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .requestToShare(let fromHostname) = decoded else {
            return XCTFail("expected .requestToShare, got \(decoded)")
        }
        XCTAssertEqual(fromHostname, "wisp-1")
        XCTAssertNil(parser.next())
    }

    func testRequestToShareHostnameClampedOnReceive() throws {
        // Hostile peer sends a payload with a huge hostname — receiver
        // must clamp before propagating so the UI banner can't be bloated.
        let huge = String(repeating: "x", count: 4096)
        let payload = try JSONEncoder().encode(RequestToSharePayload(fromHostname: huge))
        var data = Data()
        data.append(ScreenShareMessage.MessageType.requestToShare.rawValue)
        let len = UInt32(payload.count)
        data.append(UInt8((len >> 24) & 0xFF))
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))
        data.append(payload)

        var parser = ScreenShareMessageParser()
        parser.append(data)
        let decoded = try XCTUnwrap(parser.next())
        guard case .requestToShare(let fromHostname) = decoded else {
            return XCTFail("expected .requestToShare, got \(decoded)")
        }
        XCTAssertEqual(fromHostname.count, RequestToSharePayload.maxHostnameLength)
    }

    // MARK: - Remote control

    func testControlRequestRoundTrip() throws {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.controlRequest.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .controlRequest = decoded else {
            return XCTFail("expected .controlRequest, got \(decoded)")
        }
        XCTAssertNil(parser.next())
    }

    func testControlGrantedRoundTrip() throws {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.controlGranted.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .controlGranted = decoded else {
            return XCTFail("expected .controlGranted, got \(decoded)")
        }
    }

    func testControlRevokedRoundTrip() throws {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.controlRevoked(reason: "sharer revoked").encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .controlRevoked(let reason) = decoded else {
            return XCTFail("expected .controlRevoked, got \(decoded)")
        }
        XCTAssertEqual(reason, "sharer revoked")
    }

    func testControlRevokedReasonClampedOnReceive() throws {
        let huge = String(repeating: "x", count: 4096)
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.controlRevoked(reason: huge).encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .controlRevoked(let reason) = decoded else {
            return XCTFail("expected .controlRevoked, got \(decoded)")
        }
        XCTAssertEqual(reason.count, ControlRevokedPayload.maxReasonLength)
    }

    func testInputEventRoundTripEveryCase() throws {
        let events: [InputEvent] = [
            .mouseMove(x: 0.25, y: 0.75),
            .mouseDown(x: 0.1, y: 0.2, button: .left),
            .mouseUp(x: 0.1, y: 0.2, button: .right),
            .scroll(x: 0.5, y: 0.5, deltaX: -3, deltaY: 4),
            .keyDown(keyCode: 0x24, modifiers: 0x0010_0000),
            .keyUp(keyCode: 0x24, modifiers: 0)
        ]
        for event in events {
            var parser = ScreenShareMessageParser()
            parser.append(ScreenShareMessage.inputEvent(event).encode())
            let decoded = try XCTUnwrap(parser.next())
            guard case .inputEvent(let got) = decoded else {
                return XCTFail("expected .inputEvent, got \(decoded)")
            }
            XCTAssertEqual(got, event)
            XCTAssertNil(parser.next())
        }
    }

    func testControlReleasedRoundTrip() throws {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.controlReleased.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .controlReleased = decoded else {
            return XCTFail("expected .controlReleased, got \(decoded)")
        }
        XCTAssertNil(parser.next())
    }

    func testMalformedInputEventDecodesToNilWithoutCrashing() throws {
        // A well-formed frame header (type 0x09) with garbage JSON payload
        // must yield nil (no crash), and a following valid frame still parses.
        var frame = Data()
        frame.append(ScreenShareMessage.MessageType.inputEvent.rawValue)
        let garbage = Data([0x7B, 0x21, 0x40, 0x23])  // "{!@#"
        let len = UInt32(garbage.count)
        frame.append(UInt8((len >> 24) & 0xFF))
        frame.append(UInt8((len >> 16) & 0xFF))
        frame.append(UInt8((len >> 8) & 0xFF))
        frame.append(UInt8(len & 0xFF))
        frame.append(garbage)

        var parser = ScreenShareMessageParser()
        parser.append(frame)
        XCTAssertNil(parser.next())  // garbage input event → nil, consumed
        XCTAssertFalse(parser.isCorrupt)  // decode-fail is not a framing error

        // The stream is still usable for the next frame.
        parser.append(ScreenShareMessage.controlRequest.encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .controlRequest = decoded else {
            return XCTFail("expected .controlRequest after garbage input event")
        }
    }

    /// Pins the load-bearing default `nonConformingFloatDecodingStrategy =
    /// .throw` on `decodeInputEvent`'s JSONDecoder: `NaN` / `Infinity` /
    /// `-Infinity` tokens and the out-of-range literal `1e999` in coordinate
    /// or delta fields must all reject to nil. Without this, a NaN coordinate
    /// would reach `RemoteControlMapping.globalPoint` (which now defends
    /// itself too — belt and braces, see `RemoteControlMappingTests`).
    ///
    /// The quoted-string variants (`"NaN"`, `"Infinity"`, `"-Infinity"`) are
    /// the rows that actually pin the *strategy*: the bare-token forms are
    /// invalid JSON and reject under ANY strategy, but the quoted forms would
    /// start decoding the moment someone "improves" the decoder with
    /// `.convertFromString(...)` — so those rows are what turn red.
    func testInputEventNonConformingFloatsRejectToNil() throws {
        let hostilePayloads = [
            #"{"mouseMove":{"x":NaN,"y":0.5}}"#,
            #"{"mouseMove":{"x":0.5,"y":NaN}}"#,
            #"{"mouseMove":{"x":Infinity,"y":0.5}}"#,
            #"{"mouseMove":{"x":-Infinity,"y":0.5}}"#,
            #"{"mouseMove":{"x":1e999,"y":0.5}}"#,
            #"{"mouseMove":{"x":"NaN","y":0.5}}"#,
            #"{"mouseMove":{"x":"Infinity","y":0.5}}"#,
            #"{"mouseMove":{"x":0.5,"y":"-Infinity"}}"#,
            #"{"mouseDown":{"x":NaN,"y":0.5,"button":"left"}}"#,
            #"{"mouseDown":{"x":"NaN","y":0.5,"button":"left"}}"#,
            #"{"mouseUp":{"x":0.5,"y":Infinity,"button":"right"}}"#,
            #"{"scroll":{"x":0.5,"y":0.5,"deltaX":NaN,"deltaY":0}}"#,
            #"{"scroll":{"x":0.5,"y":0.5,"deltaX":"NaN","deltaY":0}}"#,
            #"{"scroll":{"x":0.5,"y":0.5,"deltaX":0,"deltaY":1e999}}"#
        ]
        for hostile in hostilePayloads {
            let payload = Data(hostile.utf8)
            var frame = Data()
            frame.append(ScreenShareMessage.MessageType.inputEvent.rawValue)
            let len = UInt32(payload.count)
            frame.append(UInt8((len >> 24) & 0xFF))
            frame.append(UInt8((len >> 16) & 0xFF))
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
            frame.append(payload)

            var parser = ScreenShareMessageParser()
            parser.append(frame)
            XCTAssertNil(parser.next(), "non-conforming float must reject: \(hostile)")
            XCTAssertFalse(parser.isCorrupt, "a rejected payload is not a framing error")

            // A valid frame after the rejected one still parses — the framing
            // survived the hostile payload.
            parser.append(ScreenShareMessage.inputEvent(.mouseMove(x: 0.5, y: 0.5)).encode())
            let decoded = try XCTUnwrap(parser.next(), "valid frame after \(hostile) must parse")
            guard case .inputEvent(.mouseMove(let x, let y)) = decoded else {
                return XCTFail("expected the valid mouseMove after \(hostile), got \(decoded)")
            }
            XCTAssertEqual(x, 0.5)
            XCTAssertEqual(y, 0.5)
        }
    }

    func testOversizedFrameLengthPoisonsParserAndBoundsBuffer() {
        // A hostile peer advertises a 4 GiB payload then slow-streams bytes.
        // The parser must reject at header-parse time, mark itself corrupt,
        // and stop buffering — never grow toward the declared size.
        var frame = Data()
        frame.append(ScreenShareMessage.MessageType.annotation.rawValue)
        frame.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // len = 0xFFFFFFFF

        var parser = ScreenShareMessageParser()
        parser.append(frame)
        XCTAssertNil(parser.next())
        XCTAssertTrue(parser.isCorrupt, "oversized length must poison the parser")

        // Further bytes are ignored (buffer stays bounded), and next() stays nil.
        parser.append(Data(repeating: 0xAB, count: 100_000))
        XCTAssertNil(parser.next())
        XCTAssertTrue(parser.isCorrupt)
    }

    func testFrameAtExactlyMaxPayloadLengthIsAccepted() throws {
        // The ceiling is inclusive: a frame declaring exactly maxPayloadLength
        // is honoured (not poisoned), so the bound doesn't reject legitimate
        // large-but-in-spec frames.
        let payload = Data(repeating: 0x20, count: ScreenShareMessage.maxPayloadLength)
        var frame = Data()
        frame.append(ScreenShareMessage.MessageType.annotation.rawValue)
        let len = UInt32(payload.count)
        frame.append(UInt8((len >> 24) & 0xFF))
        frame.append(UInt8((len >> 16) & 0xFF))
        frame.append(UInt8((len >> 8) & 0xFF))
        frame.append(UInt8(len & 0xFF))
        frame.append(payload)

        var parser = ScreenShareMessageParser()
        parser.append(frame)
        // Payload is whitespace, not valid AnnotationOp JSON → decodes to nil,
        // but crucially the parser is NOT corrupt (the length was in bounds).
        XCTAssertNil(parser.next())
        XCTAssertFalse(parser.isCorrupt)
    }

    func testUnknownMessageTypeIsSkipped() throws {
        // Hand-build a bogus message with type=0xFF, then a valid annotation.
        var bogus = Data()
        bogus.append(0xFF)  // unknown type
        bogus.append(contentsOf: [0x00, 0x00, 0x00, 0x02])  // payload len = 2 BE
        bogus.append(contentsOf: [0xDE, 0xAD])  // payload

        let good = ScreenShareMessage.annotation(.clearAll).encode()

        var parser = ScreenShareMessageParser()
        parser.append(bogus + good)

        let decoded = try XCTUnwrap(parser.next())
        guard case .annotation(.clearAll) = decoded else {
            return XCTFail("expected .annotation(.clearAll) after skipping unknown type")
        }
    }
}
