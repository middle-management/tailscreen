import XCTest

@testable import Tailscreen

/// Round-trip the parent → helper framed protocol with focus on the
/// new `contentFilter` message type. We can't exercise a real
/// `SCContentFilter` in CI (no display, no UI), so the tests use
/// arbitrary `Data` payloads — the framing layer is opaque to the
/// payload anyway.
final class CaptureHelperWireTests: XCTestCase {
    /// `contentFilter` round-trip with a small payload. Validates the
    /// new InType raw value (0x03) and that the writer + reader agree
    /// on framing.
    func testContentFilterFrameRoundTrip() throws {
        let pipe = Pipe()
        let writer = HelperControlWriter(handle: pipe.fileHandleForWriting)
        let reader = HelperControlReader(handle: pipe.fileHandleForReading)

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02])
        writer.sendContentFilter(payload)
        try pipe.fileHandleForWriting.close()

        guard let frame = reader.readNext() else {
            XCTFail("expected one frame")
            return
        }
        XCTAssertEqual(frame.type, CaptureHelperWire.InType.contentFilter.rawValue)
        XCTAssertEqual(frame.payload, payload)
    }

    func testZeroLengthContentFilter() throws {
        let pipe = Pipe()
        let writer = HelperControlWriter(handle: pipe.fileHandleForWriting)
        let reader = HelperControlReader(handle: pipe.fileHandleForReading)

        writer.sendContentFilter(Data())
        try pipe.fileHandleForWriting.close()

        guard let frame = reader.readNext() else {
            XCTFail("expected one frame")
            return
        }
        XCTAssertEqual(frame.type, CaptureHelperWire.InType.contentFilter.rawValue)
        XCTAssertEqual(frame.payload.count, 0)
    }

    /// 64 KB exercises the chunked-read path inside `readExactly` and
    /// is plausibly the largest archived `SCContentFilter` we'd see
    /// (multi-app sets with thumbnails and bundle metadata). The
    /// write happens on a background queue because macOS pipe
    /// buffers default to ~16 KB; a synchronous write would block
    /// before the reader gets a chance to drain.
    func testLargeContentFilter() throws {
        let pipe = Pipe()
        let reader = HelperControlReader(handle: pipe.fileHandleForReading)

        var rng = SystemRandomNumberGenerator()
        let size = 64 * 1024
        let payload: Data = {
            var buf = Data(count: size)
            for i in 0..<size {
                buf[i] = UInt8(rng.next() & 0xFF)
            }
            return buf
        }()
        let writeHandle = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            HelperControlWriter(handle: writeHandle).sendContentFilter(payload)
            try? writeHandle.close()
        }

        guard let frame = reader.readNext() else {
            XCTFail("expected one frame")
            return
        }
        XCTAssertEqual(frame.type, CaptureHelperWire.InType.contentFilter.rawValue)
        XCTAssertEqual(frame.payload, payload)
    }

    /// The message types should not collide on the wire — interleave
    /// `requestKeyframe`, `setBitrate`, and `contentFilter` and
    /// confirm the reader recovers each in order with the right type
    /// and payload.
    func testInterleavedMessages() throws {
        let pipe = Pipe()
        let writer = HelperControlWriter(handle: pipe.fileHandleForWriting)
        let reader = HelperControlReader(handle: pipe.fileHandleForReading)

        let filterPayload = Data([0xCA, 0xFE, 0xBA, 0xBE])
        writer.sendKeyframeRequest()
        writer.sendBitrate(2_500_000)
        writer.sendContentFilter(filterPayload)
        writer.sendShutdown()
        try pipe.fileHandleForWriting.close()

        guard let f1 = reader.readNext() else {
            XCTFail("frame 1")
            return
        }
        XCTAssertEqual(f1.type, CaptureHelperWire.InType.requestKeyframe.rawValue)
        XCTAssertEqual(f1.payload.count, 0)

        guard let f2 = reader.readNext() else {
            XCTFail("frame 2")
            return
        }
        XCTAssertEqual(f2.type, CaptureHelperWire.InType.setBitrate.rawValue)
        XCTAssertEqual(f2.payload.count, 4)
        let bitrate =
            (UInt32(f2.payload[0]) << 24) | (UInt32(f2.payload[1]) << 16) | (UInt32(f2.payload[2]) << 8)
            | UInt32(f2.payload[3])
        XCTAssertEqual(bitrate, 2_500_000)

        guard let f3 = reader.readNext() else {
            XCTFail("frame 3")
            return
        }
        XCTAssertEqual(f3.type, CaptureHelperWire.InType.contentFilter.rawValue)
        XCTAssertEqual(f3.payload, filterPayload)

        guard let f4 = reader.readNext() else {
            XCTFail("frame 4")
            return
        }
        XCTAssertEqual(f4.type, CaptureHelperWire.InType.shutdown.rawValue)
        XCTAssertEqual(f4.payload.count, 0)
    }

    /// `InType` raw values are part of the wire contract; pin them so
    /// a refactor that reorders the enum doesn't silently break helper
    /// communication.
    func testInTypeRawValuesAreStable() {
        XCTAssertEqual(CaptureHelperWire.InType.requestKeyframe.rawValue, 0x01)
        XCTAssertEqual(CaptureHelperWire.InType.setBitrate.rawValue, 0x02)
        XCTAssertEqual(CaptureHelperWire.InType.contentFilter.rawValue, 0x03)
        XCTAssertEqual(CaptureHelperWire.InType.shutdown.rawValue, 0xFF)
    }

    // MARK: - PickerSelection JSON contract

    /// `PickerSelection`'s JSON shape is the contract between the
    /// picker-helper subprocess and the capture-helper subprocess —
    /// neither side imports the other's code, they only agree on the
    /// JSON. Round-trip all three kinds so a field rename or
    /// CodingKeys regression surfaces here instead of in a runtime
    /// "couldn't decode picker selection" alert.

    func testPickerSelectionDisplayRoundTrip() throws {
        let original = PickerSelection(
            kind: .display, displayID: 12_345, windowID: nil, bundleIDs: [])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .display)
        XCTAssertEqual(decoded.displayID, 12_345)
        XCTAssertNil(decoded.windowID)
        XCTAssertEqual(decoded.bundleIDs, [])
    }

    func testPickerSelectionWindowRoundTrip() throws {
        let original = PickerSelection(
            kind: .window, displayID: nil, windowID: 98_765, bundleIDs: [])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .window)
        XCTAssertEqual(decoded.windowID, 98_765)
        XCTAssertNil(decoded.displayID)
    }

    func testPickerSelectionSingleApplicationRoundTrip() throws {
        let original = PickerSelection(
            kind: .application,
            displayID: 1,
            windowID: nil,
            bundleIDs: ["com.apple.Safari"]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.bundleIDs.count, 1)
    }

    func testPickerSelectionMultiApplicationRoundTrip() throws {
        let original = PickerSelection(
            kind: .application,
            displayID: 1,
            windowID: nil,
            bundleIDs: ["com.apple.Safari", "com.apple.Notes", "com.apple.dt.Xcode"]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.bundleIDs.count, 3)
    }

    /// `Kind` raw values are also part of the wire contract — they
    /// serialize as JSON strings. Pin them so a future enum reorder
    /// or rename surfaces here instead of in a runtime decode error.
    func testPickerSelectionKindRawValuesAreStable() {
        XCTAssertEqual(PickerSelection.Kind.display.rawValue, "display")
        XCTAssertEqual(PickerSelection.Kind.window.rawValue, "window")
        XCTAssertEqual(PickerSelection.Kind.application.rawValue, "application")
    }
}
