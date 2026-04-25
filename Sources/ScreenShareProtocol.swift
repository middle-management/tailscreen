import Foundation

/// Wire format used between ``TailscaleScreenShareServer`` and ``TailscaleScreenShareClient``.
///
/// Every message starts with a 5-byte header:
///
///     [1 byte: type][4 bytes big-endian: payload length][payload...]
///
/// Message types:
///
///     .parameterSets (0x01)   — server→client
///         payload = [4 BE: spsLen][sps bytes][4 BE: ppsLen][pps bytes]
///
///     .frame (0x02)           — server→client
///         payload = [1 byte: keyframe flag][8 BE: server timestamp ns][raw AVCC NAL units]
///
///     .annotation (0x03)      — client→server (back-channel for drawings)
///         payload = JSON-encoded ``AnnotationOp``
///
/// The timestamp uses `DispatchTime.now().uptimeNanoseconds` (mach_absolute_time),
/// which is monotonic and consistent across processes on the same machine. Lets
/// the client compute one-way encode→receive latency when both ends run locally.
enum ScreenShareMessage {
    case parameterSets(sps: Data, pps: Data)
    case frame(data: Data, isKeyframe: Bool, timestampNs: UInt64)
    case annotation(AnnotationOp)

    static let headerSize = 5

    enum MessageType: UInt8 {
        case parameterSets = 0x01
        case frame = 0x02
        case annotation = 0x03
    }

    /// Serialize this message as a wire-format packet (header + payload).
    func encode() -> Data {
        switch self {
        case .parameterSets(let sps, let pps):
            var payload = Data(capacity: 8 + sps.count + pps.count)
            payload.appendBigEndian(UInt32(sps.count))
            payload.append(sps)
            payload.appendBigEndian(UInt32(pps.count))
            payload.append(pps)
            return Self.frame(type: .parameterSets, payload: payload)

        case .frame(let data, let isKeyframe, let timestampNs):
            var payload = Data(capacity: 1 + 8 + data.count)
            payload.append(isKeyframe ? 1 : 0)
            payload.appendBigEndian(timestampNs)
            payload.append(data)
            return Self.frame(type: .frame, payload: payload)

        case .annotation(let op):
            let payload = (try? JSONEncoder().encode(op)) ?? Data()
            return Self.frame(type: .annotation, payload: payload)
        }
    }

    private static func frame(type: MessageType, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(type.rawValue)
        out.appendBigEndian(UInt32(payload.count))
        out.append(payload)
        return out
    }
}

/// Incremental parser. Feed bytes as they arrive; ``next()`` returns whole messages.
struct ScreenShareMessageParser {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> ScreenShareMessage? {
        guard buffer.count >= ScreenShareMessage.headerSize else { return nil }

        let rawType = buffer[buffer.startIndex]
        let lengthStart = buffer.index(buffer.startIndex, offsetBy: 1)
        let length = Int(buffer.readBigEndian(UInt32.self, at: lengthStart))
        let totalSize = ScreenShareMessage.headerSize + length
        guard buffer.count >= totalSize else { return nil }

        let payloadStart = buffer.index(buffer.startIndex, offsetBy: ScreenShareMessage.headerSize)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = buffer[payloadStart..<payloadEnd]

        buffer.removeSubrange(buffer.startIndex..<payloadEnd)

        guard let type = ScreenShareMessage.MessageType(rawValue: rawType) else {
            // Unknown type: frame already consumed, drop it.
            return next()
        }

        switch type {
        case .parameterSets:
            return decodeParameterSets(payload)
        case .frame:
            return decodeFrame(payload)
        case .annotation:
            return decodeAnnotation(payload)
        }
    }

    private func decodeAnnotation(_ payload: Data) -> ScreenShareMessage? {
        guard let op = try? JSONDecoder().decode(AnnotationOp.self, from: Data(payload)) else {
            return nil
        }
        return .annotation(op)
    }

    private func decodeParameterSets(_ payload: Data) -> ScreenShareMessage? {
        guard payload.count >= 8 else { return nil }
        let spsLen = Int(payload.readBigEndian(UInt32.self, at: payload.startIndex))
        let spsStart = payload.index(payload.startIndex, offsetBy: 4)
        guard payload.count >= 4 + spsLen + 4 else { return nil }
        let spsEnd = payload.index(spsStart, offsetBy: spsLen)
        let sps = Data(payload[spsStart..<spsEnd])

        let ppsLenStart = spsEnd
        let ppsLen = Int(payload.readBigEndian(UInt32.self, at: ppsLenStart))
        let ppsStart = payload.index(ppsLenStart, offsetBy: 4)
        guard payload.count >= 4 + spsLen + 4 + ppsLen else { return nil }
        let ppsEnd = payload.index(ppsStart, offsetBy: ppsLen)
        let pps = Data(payload[ppsStart..<ppsEnd])

        return .parameterSets(sps: sps, pps: pps)
    }

    private func decodeFrame(_ payload: Data) -> ScreenShareMessage? {
        guard payload.count >= 9 else { return nil }
        let isKeyframe = payload[payload.startIndex] == 1
        let timestampStart = payload.index(payload.startIndex, offsetBy: 1)
        let timestampNs = payload.readBigEndian(UInt64.self, at: timestampStart)
        let bodyStart = payload.index(timestampStart, offsetBy: 8)
        let body = Data(payload[bodyStart..<payload.endIndex])
        return .frame(data: body, isKeyframe: isKeyframe, timestampNs: timestampNs)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func readBigEndian(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(self[index])
        let b1 = UInt32(self[self.index(index, offsetBy: 1)])
        let b2 = UInt32(self[self.index(index, offsetBy: 2)])
        let b3 = UInt32(self[self.index(index, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readBigEndian(_: UInt64.Type, at index: Data.Index) -> UInt64 {
        var result: UInt64 = 0
        for offset in 0..<8 {
            result = (result << 8) | UInt64(self[self.index(index, offsetBy: offset)])
        }
        return result
    }
}
