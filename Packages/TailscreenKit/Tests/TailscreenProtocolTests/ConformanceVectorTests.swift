import Foundation
import XCTest

@testable import TailscreenProtocol

/// Runs the language-neutral conformance vectors (`conformance/vectors/`)
/// against the production codecs.
///
/// The vectors are the contract behind `docs/spec.md`; the Go suite under
/// `conformance/go` runs the same files against an implementation that
/// shares no code with this one. This suite is the other half: it is what
/// stops the vectors from drifting away from what Tailscreen actually puts
/// on the wire. A vector that only the Go side passes is a specification
/// that describes nobody's implementation.
///
/// Each case names an `op`, an `in` object and the expected `out` object;
/// `run(op:in:)` below is the same dispatch table the Go runner implements,
/// so porting the suite to a third language means porting one function.
///
/// Where a vector exercises a payload rather than a framing, it is fed
/// through the real `ScreenShareMessageParser` inside a real frame, so the
/// clamps and rejections that live in that parser are the thing under test.
final class ConformanceVectorTests: XCTestCase {

    // MARK: - Vector loading

    /// The repository's `conformance/vectors` directory, found relative to
    /// this source file so the suite needs no bundle resources.
    private static var vectorDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TailscreenProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TailscreenKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // <repo root>
            .appendingPathComponent("conformance")
            .appendingPathComponent("vectors")
    }

    private func loadJSON(_ name: String) throws -> [String: Any] {
        let url = Self.vectorDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VectorError.malformed("\(name) is not a JSON object")
        }
        return object
    }

    private enum VectorError: Error, CustomStringConvertible {
        case malformed(String)
        case unsupportedOp(String)

        var description: String {
            switch self {
            case .malformed(let why): return "malformed vector: \(why)"
            case .unsupportedOp(let op): return "no dispatch for op \(op)"
            }
        }
    }

    // MARK: - The suite

    func testConformanceVectors() throws {
        let index = try loadJSON("index.json")
        XCTAssertEqual(
            index["specVersion"] as? Int, 1,
            "vectors declare a spec version this runner does not implement")

        guard let suites = index["suites"] as? [[String: Any]], !suites.isEmpty else {
            return XCTFail("vector index lists no suites")
        }

        var ran = 0
        for entry in suites {
            guard let file = entry["file"] as? String else {
                XCTFail("suite entry has no file")
                continue
            }
            let suite = try loadJSON(file)
            guard let cases = suite["cases"] as? [[String: Any]] else {
                XCTFail("\(file) carries no cases")
                continue
            }
            XCTAssertEqual(
                cases.count, entry["cases"] as? Int ?? -1,
                "\(file): the index and the file disagree about how many cases there are")

            for testCase in cases {
                guard let id = testCase["id"] as? String,
                    let op = testCase["op"] as? String,
                    let input = testCase["in"] as? [String: Any],
                    let expected = testCase["out"] as? [String: Any]
                else {
                    XCTFail("a case in \(file) is missing id/op/in/out")
                    continue
                }
                let requirements = (testCase["requirements"] as? [String] ?? []).joined(separator: ", ")

                do {
                    let actual = try run(op: op, input: input)
                    let got = JSONValue(any: actual)
                    let want = JSONValue(any: expected)
                    XCTAssertEqual(
                        got, want,
                        "\(id) violates \(requirements)\n  op: \(op)\n  want: \(want)\n  got:  \(got)")
                } catch {
                    XCTFail("\(id) [\(requirements)]: \(error)")
                }
                ran += 1
            }
        }
        XCTAssertGreaterThan(ran, 0, "no vectors ran")
    }

    /// Every requirement a vector cites must exist in the specification —
    /// the same check the Go runner makes, so a renamed requirement fails
    /// on both sides rather than quietly losing its coverage.
    func testCitedRequirementsExistInSpec() throws {
        let specURL = Self.vectorDirectory
            .deletingLastPathComponent()  // conformance
            .deletingLastPathComponent()  // <repo root>
            .appendingPathComponent("docs")
            .appendingPathComponent("spec.md")
        guard let spec = try? String(contentsOf: specURL, encoding: .utf8) else {
            throw XCTSkip("docs/spec.md is not readable from here")
        }

        let index = try loadJSON("index.json")
        for entry in index["suites"] as? [[String: Any]] ?? [] {
            guard let file = entry["file"] as? String else { continue }
            for testCase in try loadJSON(file)["cases"] as? [[String: Any]] ?? [] {
                let id = testCase["id"] as? String ?? "?"
                let requirements = testCase["requirements"] as? [String] ?? []
                XCTAssertFalse(requirements.isEmpty, "\(id) cites no requirement")
                for requirement in requirements {
                    XCTAssertTrue(
                        spec.contains("**\(requirement)**"),
                        "\(id) cites \(requirement), which docs/spec.md does not define")
                }
            }
        }
    }

    // MARK: - Dispatch

    private func run(op: String, input: [String: Any]) throws -> [String: Any] {
        switch op {

        // ------------------------------------------------------------ UDP
        case "control.encodeSimple":
            let kind = try Self.controlKind(named: try string(input, "kind"))
            return ["bytes": hex(ScreenShareControlMessage.encode(kind))]

        case "control.decodeKind":
            let decoded = ScreenShareControlMessage.decode(try bytes(input, "bytes"))
            return ["kind": Self.orNull(decoded) { String(describing: $0) }]

        case "control.classify":
            let data = try bytes(input, "bytes")
            if data.isEmpty { return ["class": "empty"] }
            return ["class": ScreenShareControlMessage.looksLikeControl(data) ? "control" : "rtp"]

        case "hello.encode":
            let caps = ScreenShareCaps(rawValue: try uint8(input, "caps"))
            return ["bytes": hex(ScreenShareControlMessage.encodeHello(caps: caps))]

        case "hello.decodeCaps":
            let caps = ScreenShareControlMessage.decodeHelloCaps(try bytes(input, "bytes"))
            return ["caps": Int(caps.rawValue)]

        case "helloAck.encode":
            let ssrc = try uint32(input, "ssrc")
            if input["caps"] is NSNull || input["caps"] == nil {
                return ["bytes": hex(ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc))]
            }
            let caps = ScreenShareCaps(rawValue: try uint8(input, "caps"))
            return ["bytes": hex(ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc, caps: caps))]

        case "helloAck.decodeStrict":
            let ssrc = ScreenShareControlMessage.decodeHelloAck(try bytes(input, "bytes"))
            return ["ssrc": Self.orNull(ssrc) { Int($0) }]

        case "helloAck.decodeTolerant":
            guard let parsed = ScreenShareControlMessage.decodeHelloAckCaps(try bytes(input, "bytes")) else {
                return ["ssrc": NSNull(), "caps": NSNull()]
            }
            return ["ssrc": Int(parsed.ssrc), "caps": Int(parsed.caps.rawValue)]

        // -------------------------------------------------- loss recovery
        case "nack.encode":
            let entries = try (input["entries"] as? [[String: Any]] ?? []).map {
                (pid: try uint16($0, "pid"), blp: try uint16($0, "blp"))
            }
            return ["bytes": hex(ScreenShareControlMessage.encodeNACK(entries))]

        case "nack.decode":
            let decoded = ScreenShareControlMessage.decodeNACK(try bytes(input, "bytes"))
            return ["entries": decoded.map { ["pid": Int($0.pid), "blp": Int($0.blp)] }]

        case "ping.encode":
            let uptime = try uint64String(input, "serverUptimeNs")
            return ["bytes": hex(ScreenShareControlMessage.encodePing(serverUptimeNs: uptime))]

        case "ping.decode":
            let decoded = ScreenShareControlMessage.decodePing(try bytes(input, "bytes"))
            return ["serverUptimeNs": Self.orNull(decoded) { String($0) }]

        case "rr.encode":
            guard let raw = input["report"] as? [String: Any] else {
                throw VectorError.malformed("rr.encode without a report")
            }
            let report = ReceiverReport(
                fracLostQ8: try uint8(raw, "fracLostQ8"),
                extHighestSeq: try uint32(raw, "extHighestSeq"),
                jitterTicks: try uint32(raw, "jitterTicks"),
                lastPingTs: try uint64String(raw, "lastPingTs"),
                delaySincePingMs: try uint16(raw, "delaySincePingMs"),
                fecRecovered: try uint16(raw, "fecRecovered"),
                nackRecovered: try uint16(raw, "nackRecovered"))
            let include = input["includeRecoveryFields"] as? Bool ?? false
            return [
                "bytes": hex(
                    ScreenShareControlMessage.encodeReceiverReport(report, includeRecoveryFields: include))
            ]

        case "rr.decode":
            guard let report = ScreenShareControlMessage.decodeReceiverReport(try bytes(input, "bytes"))
            else { return ["report": NSNull()] }
            return [
                "report": [
                    "fracLostQ8": Int(report.fracLostQ8),
                    "extHighestSeq": Int(report.extHighestSeq),
                    "jitterTicks": Int(report.jitterTicks),
                    "lastPingTs": String(report.lastPingTs),
                    "delaySincePingMs": Int(report.delaySincePingMs),
                    "fecRecovered": Int(report.fecRecovered),
                    "nackRecovered": Int(report.nackRecovered)
                ]
            ]

        case "fec.encodeDatagram":
            let encoded = ScreenShareControlMessage.encodeFEC(
                baseSeq: try uint16(input, "baseSeq"),
                count: try int(input, "count"),
                body: try bytes(input, "body"))
            return ["bytes": hex(encoded)]

        case "fec.decodeDatagram":
            guard let parsed = ScreenShareControlMessage.decodeFEC(try bytes(input, "bytes")) else {
                return ["baseSeq": NSNull(), "count": NSNull(), "body": NSNull()]
            }
            return ["baseSeq": Int(parsed.baseSeq), "count": parsed.count, "body": hex(parsed.body)]

        case "fec.parity":
            let packets = try hexArray(input, "packets")
            return ["body": hex(FECCodec.parityBody(for: packets[...]))]

        case "fec.recover":
            let recovered = FECCodec.recover(
                missingSeq: try uint16(input, "missingSeq"),
                ssrc: try uint32(input, "ssrc"),
                members: try hexArray(input, "members"),
                body: try bytes(input, "body"))
            return ["packet": Self.orNull(recovered) { self.hex($0) }]

        // ------------------------------------------------------------ RTP
        case "rtp.encodeHeader":
            let header = RTPHeader(
                marker: input["marker"] as? Bool ?? false,
                payloadType: try uint8(input, "payloadType"),
                sequenceNumber: try uint16(input, "sequenceNumber"),
                timestamp: try uint32(input, "timestamp"),
                ssrc: try uint32(input, "ssrc"))
            var out = Data()
            header.encode(into: &out)
            return ["bytes": hex(out)]

        case "rtp.decodeHeader":
            guard let parsed = RTPHeader.decode(from: try bytes(input, "bytes")) else {
                return ["header": NSNull()]
            }
            return [
                "marker": parsed.header.marker ? 1 : 0,
                "payloadType": Int(parsed.header.payloadType),
                "sequenceNumber": Int(parsed.header.sequenceNumber),
                "timestamp": Int(parsed.header.timestamp),
                "ssrc": Int(parsed.header.ssrc),
                "payloadOffset": parsed.payloadOffset
            ]

        case "packetize.h264", "packetize.hevc":
            let nals = try hexArray(input, "nals")
            let timestamp = try uint32(input, "timestamp")
            let ssrc = try uint32(input, "ssrc")
            let startSequence = try uint16(input, "startSequence")
            let packets: [Data] =
                op == "packetize.h264"
                ? H264Packetizer().packetize(
                    nals: nals, timestamp: timestamp, ssrc: ssrc, startSequence: startSequence)
                : H265Packetizer().packetize(
                    nals: nals, timestamp: timestamp, ssrc: ssrc, startSequence: startSequence)
            return ["packets": packets.map { hex($0) }]

        // ----------------------------------------------------- TCP framing
        case "frame.encode":
            // Round-trips the vector's raw frame through the production
            // parser and back out through `encode()`, so this exercises the
            // shipping encoder rather than re-implementing the header here.
            let raw = Self.frame(type: try uint8(input, "type"), payload: try bytes(input, "payload"))
            var parser = ScreenShareMessageParser()
            parser.append(raw)
            guard let message = parser.next() else {
                throw VectorError.malformed("frame.encode vector does not parse")
            }
            return ["bytes": hex(message.encode())]

        case "frame.parse":
            var parser = ScreenShareMessageParser()
            var frames: [[String: Any]] = []
            for chunk in try hexArray(input, "chunks") {
                parser.append(chunk)
                while let message = parser.next() {
                    let encoded = message.encode()
                    let payload = encoded.dropFirst(ScreenShareMessage.headerSize)
                    frames.append([
                        "type": Int(encoded[encoded.startIndex]),
                        "payload": hex(Data(payload))
                    ])
                }
            }
            return ["frames": frames, "corrupt": parser.isCorrupt ? 1 : 0]

        // --------------------------------------------------- JSON payloads
        case "json.inputEvent.decode":
            guard case .inputEvent(let event)? = try parsePayload(input, type: .inputEvent) else {
                return ["event": NSNull()]
            }
            return ["event": Self.describe(event)]

        case "json.annotationOp.decode":
            guard case .annotation(let annotationOp)? = try parsePayload(input, type: .annotation) else {
                return ["op": NSNull()]
            }
            return ["op": Self.describe(annotationOp)]

        case "json.requestToShare.decode":
            guard case .requestToShare(let hostname)? = try parsePayload(input, type: .requestToShare)
            else { return ["fromHostname": NSNull()] }
            return ["fromHostname": hostname]

        case "json.shareResponse.decode":
            guard case .shareResponse(let accepted)? = try parsePayload(input, type: .shareResponse)
            else { return ["accepted": NSNull()] }
            return ["accepted": accepted ? 1 : 0]

        case "json.controlRevoked.decode":
            guard case .controlRevoked(let reason)? = try parsePayload(input, type: .controlRevoked)
            else { return ["reason": NSNull()] }
            return ["reason": reason]

        case "json.metadata.decode":
            guard case .metadataResponse(let metadata)? = try parsePayload(input, type: .metadataResponse)
            else { return ["metadata": NSNull()] }
            return [
                "metadata": [
                    "version": metadata.version,
                    "shareName": metadata.shareName,
                    "hostname": metadata.hostname,
                    "width": metadata.screenResolution.width,
                    "height": metadata.screenResolution.height,
                    "isSharing": metadata.isSharing ? 1 : 0,
                    "timestamp": metadata.timestamp.timeIntervalSinceReferenceDate,
                    "videoCodec": Self.orNull(metadata.videoCodec) { $0.rawValue }
                ]
            ]

        default:
            throw VectorError.unsupportedOp(op)
        }
    }

    /// Wraps a vector's JSON text in a real frame of the given type and runs
    /// it through the production parser, so the clamps and rejections under
    /// test are the shipping ones.
    private func parsePayload(
        _ input: [String: Any], type: ScreenShareMessage.MessageType
    ) throws -> ScreenShareMessage? {
        let text = try string(input, "json")
        var parser = ScreenShareMessageParser()
        parser.append(Self.frame(type: type.rawValue, payload: Data(text.utf8)))
        return parser.next()
    }

    // MARK: - Result shaping

    private static func describe(_ event: InputEvent) -> [String: Any] {
        switch event {
        case .mouseMove(let x, let y):
            return ["kind": "mouseMove", "x": x, "y": y]
        case .mouseDown(let x, let y, let button, let modifiers):
            return [
                "kind": "mouseDown", "x": x, "y": y,
                "button": button.rawValue, "modifiers": Int(modifiers.rawValue)
            ]
        case .mouseUp(let x, let y, let button, let modifiers):
            return [
                "kind": "mouseUp", "x": x, "y": y,
                "button": button.rawValue, "modifiers": Int(modifiers.rawValue)
            ]
        case .scroll(let x, let y, let deltaX, let deltaY, let modifiers):
            return [
                "kind": "scroll", "x": x, "y": y,
                "deltaX": deltaX, "deltaY": deltaY, "modifiers": Int(modifiers.rawValue)
            ]
        case .keyDown(let key, let modifiers):
            return ["kind": "keyDown", "key": Int(key), "modifiers": Int(modifiers.rawValue)]
        case .keyUp(let key, let modifiers):
            return ["kind": "keyUp", "key": Int(key), "modifiers": Int(modifiers.rawValue)]
        }
    }

    private static func describe(_ op: AnnotationOp) -> [String: Any] {
        switch op {
        case .clearAll:
            return ["kind": "clearAll"]
        case .undo(let id):
            return ["kind": "undo", "id": id.uuidString]
        case .add(let annotation):
            return [
                "kind": "add",
                "id": annotation.id.uuidString,
                "tool": annotation.tool.rawValue,
                "points": annotation.points.map { [Double($0.x), Double($0.y)] },
                "color": [
                    "r": annotation.color.r, "g": annotation.color.g,
                    "b": annotation.color.b, "a": annotation.color.a
                ],
                "width": annotation.width
            ]
        }
    }

    // MARK: - Small helpers

    private static func controlKind(named name: String) throws -> ScreenShareControlMessage {
        guard let kind = ScreenShareControlMessage.allCases.first(where: { String(describing: $0) == name })
        else { throw VectorError.malformed("unknown control name \(name)") }
        return kind
    }

    private static func frame(type: UInt8, payload: Data) -> Data {
        var out = Data([type])
        out.append(UInt8((payload.count >> 24) & 0xFF))
        out.append(UInt8((payload.count >> 16) & 0xFF))
        out.append(UInt8((payload.count >> 8) & 0xFF))
        out.append(UInt8(payload.count & 0xFF))
        out.append(payload)
        return out
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func unhex(_ string: String) throws -> Data {
        guard string.count % 2 == 0 else { throw VectorError.malformed("odd-length hex \(string)") }
        var out = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else {
                throw VectorError.malformed("invalid hex \(string)")
            }
            out.append(byte)
            index = next
        }
        return out
    }

    private func string(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] as? String else {
            throw VectorError.malformed("\(key) is not a string")
        }
        return value
    }

    private func bytes(_ input: [String: Any], _ key: String) throws -> Data {
        try unhex(try string(input, key))
    }

    private func hexArray(_ input: [String: Any], _ key: String) throws -> [Data] {
        guard let values = input[key] as? [String] else {
            throw VectorError.malformed("\(key) is not an array of hex strings")
        }
        return try values.map { try unhex($0) }
    }

    /// Every integer in a vector is exactly representable as a `Double`
    /// (the one field that is not — the 64-bit ping echo — travels as a
    /// string), so one numeric accessor serves them all.
    private func number(_ input: [String: Any], _ key: String) throws -> Double {
        if let value = input[key] as? NSNumber { return value.doubleValue }
        if let value = input[key] as? Int { return Double(value) }
        if let value = input[key] as? Double { return value }
        throw VectorError.malformed("\(key) is not a number")
    }

    private func int(_ input: [String: Any], _ key: String) throws -> Int {
        Int(try number(input, key))
    }

    private func uint8(_ input: [String: Any], _ key: String) throws -> UInt8 {
        UInt8(truncatingIfNeeded: try int(input, key))
    }

    private func uint16(_ input: [String: Any], _ key: String) throws -> UInt16 {
        UInt16(truncatingIfNeeded: try int(input, key))
    }

    private func uint32(_ input: [String: Any], _ key: String) throws -> UInt32 {
        UInt32(UInt64(try number(input, key)) & 0xFFFF_FFFF)
    }

    /// A decoded value or `NSNull`, in one place — the dictionaries handed
    /// back to the comparison are `[String: Any]`, and every "or null" leg
    /// spelling this inline invited a type-inference surprise per call site.
    private static func orNull<Wrapped>(_ value: Wrapped?, _ transform: (Wrapped) -> Any) -> Any {
        let mapped: Any? = value.map(transform)
        return mapped ?? NSNull()
    }

    /// 64-bit clock values travel as decimal strings: a JSON number loses
    /// precision above 2^53, and these are nanosecond counters.
    private func uint64String(_ input: [String: Any], _ key: String) throws -> UInt64 {
        guard let value = UInt64(try string(input, key)) else {
            throw VectorError.malformed("\(key) is not a 64-bit decimal string")
        }
        return value
    }
}

/// Comparison form for vector results. Booleans collapse into numbers on both
/// sides, because `JSONSerialization` hands back `NSNumber` for both and
/// telling them apart portably is not worth a wire-format test's while.
private enum JSONValue: Equatable, CustomStringConvertible {
    case null
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any: Any?) {
        switch any {
        case nil, is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .number(value ? 1 : 0)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as Int:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as [Any]:
            self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: any))
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int64(value)) : String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let values): return "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .object(let values):
            let pairs = values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}
