import Foundation

/// Wire format for the **annotation back-channel** between viewer and sharer.
///
/// Video runs over UDP/RTP (see ``RTPPacket.swift``); annotations run over a
/// separate TCP connection because strokes need reliable, ordered delivery —
/// a dropped UDP datagram would leave a visual gap in the middle of a stroke.
/// The TCP socket on port 7447 doubles as the peer-discovery presence beacon:
/// `TailscalePeerDiscovery` connects, sends nothing, then closes; an
/// annotation client connects and starts streaming framed messages.
///
/// Every message starts with a 5-byte header:
///
///     [1 byte: type][4 bytes big-endian: payload length][payload...]
///
/// The only message type today:
///
///     .annotation (0x03)      — viewer→sharer
///         payload = JSON-encoded ``AnnotationOp``
enum ScreenShareMessage {
    case annotation(AnnotationOp)

    static let headerSize = 5

    enum MessageType: UInt8 {
        case annotation = 0x03
    }

    /// Serialize this message as a wire-format packet (header + payload).
    func encode() -> Data {
        switch self {
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
            // Unknown type: payload already consumed, drop it.
            return next()
        }

        switch type {
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
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readBigEndian(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(self[index])
        let b1 = UInt32(self[self.index(index, offsetBy: 1)])
        let b2 = UInt32(self[self.index(index, offsetBy: 2)])
        let b3 = UInt32(self[self.index(index, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
