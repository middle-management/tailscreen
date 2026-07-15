import XCTest

@testable import Tailscreen

/// Single source of truth for **every** wire byte Tailscreen puts on a pipe
/// or socket, pinned per channel. Three legs per channel:
///
///   1. **Exactness** — every pinned row matches the live constant. A
///      renumbered byte fails here: if the renumbering is intentional,
///      update the registry row *and* confirm no shipped peer depends on
///      the old value (see the PROFILE_NO / HELLO_DENY back-compat notes in
///      `RTPPacket.swift`).
///   2. **Exhaustiveness** — every live enum case has a pinned row
///      (via `CaseIterable`), so a new case added without updating the
///      registry fails by name.
///   3. **Uniqueness** — no two rows in one channel claim the same byte;
///      the failure names both claimants.
///
/// Uniqueness is deliberately scoped *per channel*: the TCP message-type
/// space and the UDP control-byte space overlap by design (both use
/// 0x03–0x0A), and the helper wire's `OutType`/`InType` ride different
/// pipes (both use 0x01–0x05 and 0xFF). Asserting cross-channel uniqueness
/// would institutionalize a false invariant — see
/// `testTCPAndUDPSpacesAreDisjointOnPurpose`.
final class WireByteRegistryTests: XCTestCase {
    /// One pinned row: the constant's source-level case name and its wire value.
    private struct WireRow {
        let name: String
        let value: UInt8

        init(_ name: String, _ value: UInt8) {
            self.name = name
            self.value = value
        }
    }

    private static func hex(_ value: UInt8) -> String {
        String(format: "0x%02X", value)
    }

    /// Assert the three registry legs for one enum-backed channel.
    private func assertRegistry<Wire: CaseIterable & RawRepresentable>(
        channel: String,
        live _: Wire.Type,
        pinned: [WireRow],
        file: StaticString = #filePath,
        line: UInt = #line
    ) where Wire.RawValue == UInt8 {
        // Leg 3 — uniqueness within the channel.
        var claimants: [UInt8: String] = [:]
        for row in pinned {
            if let existing = claimants[row.value] {
                XCTFail(
                    "\(channel): \(existing) and \(row.name) both claim \(Self.hex(row.value)) — "
                        + "byte collision; pick the next free value for the newcomer.",
                    file: file, line: line)
            }
            claimants[row.value] = row.name
        }

        let liveByName = Dictionary(
            uniqueKeysWithValues: Wire.allCases.map { (String(describing: $0), $0.rawValue) })

        // Leg 1 — exactness: each pinned row matches the live constant.
        for row in pinned {
            guard let liveValue = liveByName[row.name] else {
                XCTFail(
                    "\(channel): registry pins \(row.name) = \(Self.hex(row.value)) but no such case "
                        + "exists in the enum — removed or renamed? A shipped byte must not be dropped "
                        + "silently; update the registry row in the same change.",
                    file: file, line: line)
                continue
            }
            XCTAssertEqual(
                liveValue, row.value,
                "\(channel): \(row.name) is \(Self.hex(liveValue)) in source but the registry pins "
                    + "\(Self.hex(row.value)). If this renumbering is intentional, update the registry "
                    + "row AND confirm no shipped peer depends on the old value (wire compatibility); "
                    + "if not, you collided with an existing byte — pick the next free value.",
                file: file, line: line)
        }

        // Leg 2 — exhaustiveness: every live case has a pinned row.
        let pinnedNames = Set(pinned.map(\.name))
        for wireCase in Wire.allCases {
            let name = String(describing: wireCase)
            XCTAssertTrue(
                pinnedNames.contains(name),
                "\(channel): live case \(name) (= \(Self.hex(wireCase.rawValue))) has no registry row — "
                    + "add it to the pinned table in WireByteRegistryTests so the byte is protected.",
                file: file, line: line)
        }
    }

    // MARK: - Channel A: TCP framed control channel

    func testChannelATCPMessageTypes() {
        assertRegistry(
            channel: "TCP MessageType",
            live: ScreenShareMessage.MessageType.self,
            pinned: [
                // 0x00–0x02 are historical/reserved — see the reserved-gap
                // test below. Don't fill the gap without checking what
                // shipped peers do with those bytes.
                WireRow("annotation", 0x03),
                WireRow("requestToShare", 0x04),
                WireRow("shareResponse", 0x05),
                WireRow("controlRequest", 0x06),
                WireRow("controlGranted", 0x07),
                WireRow("controlRevoked", 0x08),
                WireRow("inputEvent", 0x09),
                WireRow("controlReleased", 0x0A)
            ])
    }

    func testChannelATCPFramingConstants() {
        XCTAssertEqual(ScreenShareMessage.headerSize, 5, "TCP framing header is [type:1][len:4 BE]")
        XCTAssertEqual(
            ScreenShareMessage.maxPayloadLength, 1 << 20,
            "1 MiB payload ceiling is the DoS guard ScreenShareMessageParser.isCorrupt enforces")
    }

    func testChannelATCPReservedGap() {
        // 0x00–0x02 are unassigned (historical). Recording them as reserved
        // so nobody "fills the gap" without noticing old peers may treat
        // them specially.
        for reserved: UInt8 in [0x00, 0x01, 0x02] {
            XCTAssertNil(
                ScreenShareMessage.MessageType(rawValue: reserved),
                "TCP MessageType \(Self.hex(reserved)) is reserved (historical); don't assign it "
                    + "without checking shipped-peer behavior.")
        }
    }

    // MARK: - Channel B: UDP control bytes

    func testChannelBUDPControlBytes() {
        assertRegistry(
            channel: "UDP control",
            live: ScreenShareControlMessage.self,
            pinned: [
                WireRow("hello", 0x00),
                WireRow("keepalive", 0x01),
                WireRow("bye", 0x02),
                WireRow("pli", 0x03),
                WireRow("helloAck", 0x04),
                WireRow("serverBye", 0x05),
                WireRow("helloPending", 0x06),
                WireRow("codecUnsupported", 0x07),
                WireRow("helloDenied", 0x08),
                WireRow("profileUnsupported", 0x09),
                WireRow("nack", 0x0A),
                WireRow("receiverReport", 0x0B),
                WireRow("ping", 0x0C)
            ])
    }

    func testChannelBUDPControlSpaceDisjointFromRTP() {
        // Channel invariant: every control byte ≤ 0x7F, so `looksLikeControl`
        // keeps the space disjoint from RTP's first-byte range 0x80–0xBF.
        for kind in ScreenShareControlMessage.allCases {
            XCTAssertLessThanOrEqual(
                kind.rawValue, 0x7F,
                "UDP control byte \(kind) = \(Self.hex(kind.rawValue)) would collide with the RTP "
                    + "first-byte space (V=2 ⇒ 0x80–0xBF); control bytes must stay ≤ 0x7F.")
            XCTAssertTrue(
                ScreenShareControlMessage.looksLikeControl(ScreenShareControlMessage.encode(kind)),
                "looksLikeControl must classify \(kind) as control")
            XCTAssertEqual(
                ScreenShareControlMessage.decode(ScreenShareControlMessage.encode(kind)), kind)
        }
        // And RTP first bytes must never look like control.
        for rtpFirstByte: UInt8 in [0x80, 0xB3, 0xBF] {
            XCTAssertFalse(
                ScreenShareControlMessage.looksLikeControl(Data([rtpFirstByte, 0x00])),
                "\(Self.hex(rtpFirstByte)) is in the RTP V=2 range and must not classify as control")
        }
    }

    func testChannelBCapabilityBits() {
        // ScreenShareCaps rides the extended HELLO/HELLO_ACK as bit flags —
        // uniqueness here means bit-disjointness, not byte-distinctness.
        // NOTE: the XOR-FEC plan reserves the next cap bit; coordinate before
        // taking 1 << 2.
        let caps: [(name: String, value: ScreenShareCaps)] = [
            ("nack", .nack),
            ("receiverReport", .receiverReport)
        ]
        XCTAssertEqual(ScreenShareCaps.nack.rawValue, 1 << 0)
        XCTAssertEqual(ScreenShareCaps.receiverReport.rawValue, 1 << 1)
        for (i, a) in caps.enumerated() {
            XCTAssertEqual(
                a.value.rawValue.nonzeroBitCount, 1,
                "cap \(a.name) must be a single bit")
            for b in caps.dropFirst(i + 1) {
                XCTAssertEqual(
                    a.value.rawValue & b.value.rawValue, 0,
                    "caps \(a.name) and \(b.name) share a bit — a new cap must not shadow an old one")
            }
        }
    }

    // MARK: - Channel C: capture-helper wire (two independent type spaces)

    func testChannelCHelperOutTypes() {
        assertRegistry(
            channel: "helper OutType (helper→main)",
            live: CaptureHelperWire.OutType.self,
            pinned: [
                WireRow("accessUnit", 0x01),
                WireRow("parameterSets", 0x02),
                WireRow("firstFrame", 0x03),
                WireRow("previewJPEG", 0x04),
                WireRow("userStopped", 0x05),
                WireRow("heartbeat", 0x06),
                WireRow("audioAccessUnit", 0x07),
                WireRow("logLine", 0x10),
                WireRow("fatal", 0xFF)
            ])
    }

    func testChannelCHelperInTypes() {
        // Independent from OutType by construction: uniqueness is asserted
        // within each table, never across the two — both legitimately use
        // 0x01–0x05 and 0xFF because they ride different pipes.
        assertRegistry(
            channel: "helper InType (main→helper)",
            live: CaptureHelperWire.InType.self,
            pinned: [
                WireRow("requestKeyframe", 0x01),
                WireRow("setBitrate", 0x02),
                WireRow("contentFilter", 0x03),
                WireRow("setAudioEnabled", 0x04),
                WireRow("setFrameInterval", 0x05),
                WireRow("shutdown", 0xFF)
            ])
    }

    // MARK: - Channel D: picker-helper framing (no type byte)

    func testChannelDPickerFramingRoundTrip() throws {
        // No named constants to table — pin the framing behaviorally with the
        // production writer and the production reader on a real pipe.
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42])
        let pipe = Pipe()
        PickerHelperFraming.writeFramedPayload(payload, to: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let got = PickerHelperClient.readFramed(pipe.fileHandleForReading)
        XCTAssertEqual(got, payload, "picker framing writer → reader must round-trip byte-identically")
    }

    func testChannelDPickerFramingHeaderIsFourByteBigEndian() throws {
        let payload = Data(repeating: 0xAB, count: 0x0102)
        let pipe = Pipe()
        PickerHelperFraming.writeFramedPayload(payload, to: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let raw = try XCTUnwrap(pipe.fileHandleForReading.readToEnd())
        XCTAssertEqual(raw.count, 4 + payload.count)
        // Hand-decode the header: exactly 4 bytes, big-endian length.
        XCTAssertEqual(Array(raw.prefix(4)), [0x00, 0x00, 0x01, 0x02])
    }

    func testChannelDPickerFramingZeroLengthMeansCancel() throws {
        let pipe = Pipe()
        PickerHelperFraming.writeFramedPayload(Data(), to: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        XCTAssertNil(
            PickerHelperClient.readFramed(pipe.fileHandleForReading),
            "length == 0 is the cancel signal and must read as nil")
    }

    // MARK: - Channel E: RTP payload types + reserved SSRCs

    func testChannelERTPPayloadTypes() {
        let pts: [(name: String, value: UInt8)] = [
            ("h264PayloadType", RTPHeader.h264PayloadType),
            ("hevcPayloadType", RTPHeader.hevcPayloadType),
            ("aacPayloadType", RTPHeader.aacPayloadType),
            ("systemAudioPayloadType", RTPHeader.systemAudioPayloadType)
        ]
        XCTAssertEqual(RTPHeader.h264PayloadType, 96)
        XCTAssertEqual(RTPHeader.hevcPayloadType, 97)
        XCTAssertEqual(RTPHeader.aacPayloadType, 98)
        XCTAssertEqual(RTPHeader.systemAudioPayloadType, 99)
        var claimants: [UInt8: String] = [:]
        for pt in pts {
            XCTAssertTrue(
                (96...127).contains(pt.value),
                "\(pt.name) = \(pt.value) is outside the RTP dynamic payload-type range 96...127")
            if let existing = claimants[pt.value] {
                XCTFail("\(existing) and \(pt.name) both claim PT \(pt.value) — pick the next free value")
            }
            claimants[pt.value] = pt.name
        }
    }

    func testChannelEReservedSSRCOrdering() {
        // Sharer voice owns SSRC 0 (the server builds its VoiceChannel with
        // localSSRC: 0), system audio owns the reserved SSRC 1, and viewer
        // SSRCs are allocated from firstViewerSSRC up. The ordering invariant
        // is what keeps the three spaces disjoint.
        let sharerVoiceSSRC: UInt32 = 0
        XCTAssertEqual(RTPHeader.systemAudioSSRC, 1)
        XCTAssertEqual(RTPHeader.firstViewerSSRC, 2)
        XCTAssertLessThan(sharerVoiceSSRC, RTPHeader.systemAudioSSRC)
        XCTAssertLessThan(RTPHeader.systemAudioSSRC, RTPHeader.firstViewerSSRC)
    }

    // MARK: - Cross-channel documentation

    func testTCPAndUDPSpacesAreDisjointOnPurpose() {
        // Deliberately-passing documentation assertion: TCP 0x0A
        // (controlReleased) and UDP 0x0A (nack) coexist because the TCP
        // message-type space and the UDP control-byte space are disjoint BY
        // DESIGN (different transports, different parsers). If you found this
        // test because the values look like a collision: they aren't — do not
        // renumber either side, and do not add cross-channel uniqueness here.
        XCTAssertEqual(ScreenShareMessage.MessageType.controlReleased.rawValue, 0x0A)
        XCTAssertEqual(ScreenShareControlMessage.nack.rawValue, 0x0A)
    }
}
