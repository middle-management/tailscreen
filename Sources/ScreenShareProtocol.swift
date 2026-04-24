import Foundation

/// Wire format used on the **TCP control channel** between
/// ``TailscaleScreenShareServer`` and ``TailscaleScreenShareClient``.
///
/// Media (encoded H.264 access units) moves out-of-band on the **UDP media
/// channel** as standards-compliant RTP (RFC 3550 + RFC 6184); see
/// ``RTPPacketizer`` and ``RTPDepacketizer``.
///
/// Control messages are small and rare enough that TCP's reliability wins
/// over UDP's latency. Every message starts with a 5-byte header:
///
///     [1 byte: type][4 bytes big-endian: payload length][payload...]
///
/// Message types:
///
///     .parameterSets     (0x02) sharer → viewer. Sent on connect and before
///                               every IDR.
///                               payload = [4 BE: spsLen][sps][4 BE: ppsLen][pps]
///
///     .keyframeRequest   (0x03) viewer → sharer. Sent when the RTP
///                               depacketizer notices a gap.
///                               payload = empty
///
///     .keyframe          (0x04) sharer → viewer. The full AVCC-formatted
///                               IDR access unit. Keyframes ride the TCP
///                               control channel instead of RTP/UDP because
///                               a 100–500 KB IDR fragments into ~70 FU-A
///                               packets over MTU — a single UDP loss used
///                               to discard the whole frame and start a
///                               keyframe-request loop that never converged.
///                               Deltas still go via RTP.
///                               payload = [8 BE: uptimeNs][4 BE: dataLen][data]
enum ScreenShareMessage {
    case parameterSets(sps: Data, pps: Data)
    case keyframeRequest
    case keyframe(timestampNs: UInt64, data: Data)

    static let headerSize = 5

    enum MessageType: UInt8 {
        case parameterSets = 0x02
        case keyframeRequest = 0x03
        case keyframe = 0x04
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

        case .keyframeRequest:
            return Self.frame(type: .keyframeRequest, payload: Data())

        case .keyframe(let ts, let data):
            var payload = Data(capacity: 8 + 4 + data.count)
            payload.appendBigEndian(ts)
            payload.appendBigEndian(UInt32(data.count))
            payload.append(data)
            return Self.frame(type: .keyframe, payload: payload)
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
        case .keyframeRequest:
            return .keyframeRequest
        case .keyframe:
            return decodeKeyframe(payload)
        }
    }

    private func decodeKeyframe(_ payload: Data) -> ScreenShareMessage? {
        guard payload.count >= 12 else { return nil }
        let ts = payload.readBigEndian(UInt64.self, at: payload.startIndex)
        let dataLenStart = payload.index(payload.startIndex, offsetBy: 8)
        let dataLen = Int(payload.readBigEndian(UInt32.self, at: dataLenStart))
        guard payload.count >= 12 + dataLen else { return nil }
        let dataStart = payload.index(dataLenStart, offsetBy: 4)
        let dataEnd = payload.index(dataStart, offsetBy: dataLen)
        let data = Data(payload[dataStart..<dataEnd])
        return .keyframe(timestampNs: ts, data: data)
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
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

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

    func readBigEndian(_: UInt16.Type, at index: Data.Index) -> UInt16 {
        let b0 = UInt16(self[index])
        let b1 = UInt16(self[self.index(index, offsetBy: 1)])
        return (b0 << 8) | b1
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
