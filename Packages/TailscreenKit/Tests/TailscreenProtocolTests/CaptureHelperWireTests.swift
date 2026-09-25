import XCTest

@testable import TailscreenProtocol

/// Round-trips the parent ↔ helper framed protocol. Uses arbitrary `Data`
/// payloads (no real `SCContentFilter` in CI) since framing is payload-opaque.
final class CaptureHelperWireTests: XCTestCase {
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

    /// 64 KB exercises `readExactly`'s chunked-read path. Write happens on a
    /// background queue: pipe buffers default to ~16 KB, so a synchronous
    /// write would block before the reader can drain.
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

    /// Pins the wire contract against an enum reorder.
    func testInTypeRawValuesAreStable() {
        XCTAssertEqual(CaptureHelperWire.InType.requestKeyframe.rawValue, 0x01)
        XCTAssertEqual(CaptureHelperWire.InType.setBitrate.rawValue, 0x02)
        XCTAssertEqual(CaptureHelperWire.InType.contentFilter.rawValue, 0x03)
        XCTAssertEqual(CaptureHelperWire.InType.setAudioEnabled.rawValue, 0x04)
        XCTAssertEqual(CaptureHelperWire.InType.shutdown.rawValue, 0xFF)
    }

    func testSystemAudioWireRawValuesAreStable() {
        XCTAssertEqual(CaptureHelperWire.OutType.audioAccessUnit.rawValue, 0x07)
    }

    // MARK: - System-audio frame round-trips

    func testAudioAccessUnitFrameRoundTrip() throws {
        let pipe = Pipe()
        let writer = HelperFrameWriter(handle: pipe.fileHandleForWriting)
        let reader = HelperFrameReader(handle: pipe.fileHandleForReading)

        let au = Data([0x21, 0x00, 0x03, 0xFF, 0xAB])
        writer.writeAudioAccessUnit(au)
        try pipe.fileHandleForWriting.close()

        guard let frame = reader.readNext() else {
            XCTFail("expected one frame")
            return
        }
        XCTAssertEqual(frame.type, CaptureHelperWire.OutType.audioAccessUnit.rawValue)
        XCTAssertEqual(frame.payload, au)
    }

    func testSetAudioEnabledFrameRoundTrip() throws {
        let pipe = Pipe()
        let writer = HelperControlWriter(handle: pipe.fileHandleForWriting)
        let reader = HelperControlReader(handle: pipe.fileHandleForReading)

        writer.sendAudioEnabled(true)
        writer.sendAudioEnabled(false)
        try pipe.fileHandleForWriting.close()

        guard let f1 = reader.readNext() else {
            XCTFail("frame 1")
            return
        }
        XCTAssertEqual(f1.type, CaptureHelperWire.InType.setAudioEnabled.rawValue)
        XCTAssertEqual(f1.payload, Data([1]))

        guard let f2 = reader.readNext() else {
            XCTFail("frame 2")
            return
        }
        XCTAssertEqual(f2.type, CaptureHelperWire.InType.setAudioEnabled.rawValue)
        XCTAssertEqual(f2.payload, Data([0]))
    }

    // MARK: - PickerSelection captureAudio field

    /// Backward compatible: JSON from an older picker-helper (no such key) decodes with `captureAudio == false`.
    func testPickerSelectionCaptureAudioRoundTrip() throws {
        let original = PickerSelection(
            kind: .display, displayID: 1, windowID: nil, bundleIDs: [], captureAudio: true)
        let decoded = try JSONDecoder().decode(
            PickerSelection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.captureAudio)
    }

    func testPickerSelectionDefaultsCaptureAudioFalse() throws {
        let selection = PickerSelection(kind: .display, displayID: 1, windowID: nil, bundleIDs: [])
        XCTAssertFalse(selection.captureAudio)
    }

    func testPickerSelectionOldJSONDecodesCaptureAudioFalse() throws {
        let json = Data(#"{"kind":"display","displayID":1,"bundleIDs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: json)
        XCTAssertFalse(decoded.captureAudio)
        XCTAssertTrue(decoded.settingCaptureAudio(true).captureAudio)
    }

    // MARK: - PickerSelection JSON contract

    /// `PickerSelection`'s JSON is the only contract between the picker-helper
    /// and capture-helper subprocesses — neither imports the other's code.

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

    /// Raw values serialize as JSON strings; pin against enum reorder/rename.
    func testPickerSelectionKindRawValuesAreStable() {
        XCTAssertEqual(PickerSelection.Kind.display.rawValue, "display")
        XCTAssertEqual(PickerSelection.Kind.window.rawValue, "window")
        XCTAssertEqual(PickerSelection.Kind.application.rawValue, "application")
    }
}
