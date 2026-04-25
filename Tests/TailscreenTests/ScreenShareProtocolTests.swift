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
        let op = AnnotationOp.add(Annotation(
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

    func testUnknownMessageTypeIsSkipped() throws {
        // Hand-build a bogus message with type=0xFF, then a valid annotation.
        var bogus = Data()
        bogus.append(0xFF)                                  // unknown type
        bogus.append(contentsOf: [0x00, 0x00, 0x00, 0x02])  // payload len = 2 BE
        bogus.append(contentsOf: [0xDE, 0xAD])              // payload

        let good = ScreenShareMessage.annotation(.clearAll).encode()

        var parser = ScreenShareMessageParser()
        parser.append(bogus + good)

        let decoded = try XCTUnwrap(parser.next())
        guard case .annotation(.clearAll) = decoded else {
            return XCTFail("expected .annotation(.clearAll) after skipping unknown type")
        }
    }
}
