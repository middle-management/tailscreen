import Foundation

/// Wire format used between ``TailscaleScreenShareServer`` and ``TailscaleScreenShareClient``.
///
/// Every message starts with a 5-byte header:
///
///     [1 byte: type][4 bytes big-endian: payload length][payload...]
///
/// There are two message types:
///
///     .parameterSets (0x01)
///         payload = [4 BE: spsLen][sps bytes][4 BE: ppsLen][pps bytes]
///
///     .frame (0x02)
///         payload = [1 byte: keyframe flag][raw AVCC NAL units]
enum ScreenShareMessage {
    case parameterSets(sps: Data, pps: Data)
    case frame(data: Data, isKeyframe: Bool)

    static let headerSize = 5

    enum MessageType: UInt8 {
        case parameterSets = 0x01
        case frame = 0x02
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

        case .frame(let data, let isKeyframe):
            var payload = Data(capacity: 1 + data.count)
            payload.append(isKeyframe ? 1 : 0)
            payload.append(data)
            return Self.frame(type: .frame, payload: payload)
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
        }
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
        guard !payload.isEmpty else { return nil }
        let isKeyframe = payload[payload.startIndex] == 1
        let bodyStart = payload.index(payload.startIndex, offsetBy: 1)
        let body = Data(payload[bodyStart..<payload.endIndex])
        return .frame(data: body, isKeyframe: isKeyframe)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readBigEndian(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let end = self.index(index, offsetBy: 4)
        return self[index..<end].withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { dst in
                dst.copyBytes(from: raw)
            }
            return UInt32(bigEndian: value)
        }
    }
}
