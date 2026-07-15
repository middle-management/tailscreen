import Foundation

/// Wire format for the **control channel** between Tailscreen peers.
///
/// Video runs over UDP/RTP (see ``RTPPacket.swift``); the control channel
/// runs over a separate TCP connection because its messages need reliable,
/// ordered delivery — a dropped datagram would leave a visual gap in the
/// middle of an annotation stroke, or silently swallow a request-to-share
/// prompt. `TailscreenControlListener` accepts these connections on
/// port 7447 and demultiplexes by message type.
///
/// Every message starts with a 5-byte header:
///
///     [1 byte: type][4 bytes big-endian: payload length][payload...]
///
/// Message types:
///
///     .annotation     (0x03)  — viewer→sharer
///         payload = JSON-encoded ``AnnotationOp``
///     .requestToShare (0x04)  — peer→peer
///         payload = JSON-encoded ``RequestToSharePayload``
///     .shareResponse  (0x05)  — request-to-share receiver→requester,
///         sent back on the SAME TCP connection the request arrived on
///         (no dial-back, so the answer provably reaches the actual
///         requester). payload = JSON-encoded ``TailscreenRequest``
///         (`.acceptShare` / `.declineShare`). Old peers' parsers drop
///         unknown type bytes, so this is backward compatible — a legacy
///         requester just never sees an answer.
///     .controlRequest (0x06)  — viewer→sharer
///         "please grant me remote control." Empty payload.
///     .controlGranted (0x07)  — sharer→viewer
///         the sharer granted this viewer control. Empty payload.
///     .controlRevoked (0x08)  — sharer→viewer
///         the sharer revoked (or never granted) control. payload = JSON
///         `ControlRevokedPayload` carrying a short reason string.
///     .inputEvent     (0x09)  — viewer→sharer
///         one ``InputEvent`` (mouse/scroll/key) to inject on the sharer's
///         machine. payload = JSON-encoded ``InputEvent``. Honoured only
///         from the current grantee's connection; dropped otherwise.
enum ScreenShareMessage {
    case annotation(AnnotationOp)
    case requestToShare(fromHostname: String)
    case shareResponse(accepted: Bool)
    case controlRequest
    case controlGranted
    case controlRevoked(reason: String)
    case inputEvent(InputEvent)
    case controlReleased

    static let headerSize = 5

    /// Hard ceiling on a single frame's payload. Every legitimate payload
    /// (annotation op, input event, request/response JSON) is well under a
    /// kilobyte; the cap stops a hostile peer from advertising a 4 GiB length
    /// and slow-streaming bytes to grow the parser's buffer without bound —
    /// especially now that a privileged `.inputEvent` consumer rides this
    /// channel. A frame declaring more than this poisons the parser (the
    /// stream is unrecoverable) and the receive loop closes the connection.
    static let maxPayloadLength = 1 << 20  // 1 MiB

    enum MessageType: UInt8 {
        case annotation = 0x03
        case requestToShare = 0x04
        case shareResponse = 0x05
        case controlRequest = 0x06
        case controlGranted = 0x07
        case controlRevoked = 0x08
        case inputEvent = 0x09
        // 0x0A–0x0C are used by the UDP control byte space (NACK/RR/PING);
        // this is the disjoint TCP message-type space, so 0x0A is free here.
        case controlReleased = 0x0A
    }

    /// Serialize this message as a wire-format packet (header + payload).
    func encode() -> Data {
        switch self {
        case .annotation(let op):
            let payload = (try? JSONEncoder().encode(op)) ?? Data()
            return Self.frame(type: .annotation, payload: payload)
        case .requestToShare(let fromHostname):
            let payload =
                (try? JSONEncoder().encode(RequestToSharePayload(fromHostname: fromHostname)))
                ?? Data()
            return Self.frame(type: .requestToShare, payload: payload)
        case .shareResponse(let accepted):
            let request: TailscreenRequest = accepted ? .acceptShare : .declineShare
            let payload = (try? JSONEncoder().encode(request)) ?? Data()
            return Self.frame(type: .shareResponse, payload: payload)
        case .controlRequest:
            return Self.frame(type: .controlRequest, payload: Data())
        case .controlGranted:
            return Self.frame(type: .controlGranted, payload: Data())
        case .controlRevoked(let reason):
            let payload =
                (try? JSONEncoder().encode(ControlRevokedPayload(reason: reason))) ?? Data()
            return Self.frame(type: .controlRevoked, payload: payload)
        case .inputEvent(let event):
            let payload = (try? JSONEncoder().encode(event)) ?? Data()
            return Self.frame(type: .inputEvent, payload: payload)
        case .controlReleased:
            return Self.frame(type: .controlReleased, payload: Data())
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
    /// Set once a frame declares a payload longer than
    /// ``ScreenShareMessage/maxPayloadLength`` — the stream is unrecoverable
    /// (we can't know where the next frame starts), so ``next()`` returns nil
    /// forever and the receive loop should close the connection.
    private(set) var isCorrupt = false

    mutating func append(_ data: Data) {
        // Once poisoned, stop buffering — don't let a hostile peer keep
        // growing memory after an oversized-length rejection.
        guard !isCorrupt else { return }
        buffer.append(data)
    }

    mutating func next() -> ScreenShareMessage? {
        guard !isCorrupt else { return nil }
        guard buffer.count >= ScreenShareMessage.headerSize else { return nil }

        let rawType = buffer[buffer.startIndex]
        let lengthStart = buffer.index(buffer.startIndex, offsetBy: 1)
        let length = Int(buffer.readBigEndian(UInt32.self, at: lengthStart))
        // Reject an oversized frame at header-parse time — BEFORE buffering
        // its payload — so a bogus 4 GiB length can't grow the buffer.
        guard length <= ScreenShareMessage.maxPayloadLength else {
            isCorrupt = true
            buffer.removeAll(keepingCapacity: false)
            return nil
        }
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
        case .requestToShare:
            return decodeRequestToShare(payload)
        case .shareResponse:
            return decodeShareResponse(payload)
        case .controlRequest:
            return .controlRequest
        case .controlGranted:
            return .controlGranted
        case .controlRevoked:
            return decodeControlRevoked(payload)
        case .inputEvent:
            return decodeInputEvent(payload)
        case .controlReleased:
            return .controlReleased
        }
    }

    private func decodeAnnotation(_ payload: Data) -> ScreenShareMessage? {
        guard let op = try? JSONDecoder().decode(AnnotationOp.self, from: Data(payload)) else {
            return nil
        }
        return .annotation(op)
    }

    private func decodeRequestToShare(_ payload: Data) -> ScreenShareMessage? {
        guard
            let request = try? JSONDecoder().decode(
                RequestToSharePayload.self, from: Data(payload))
        else { return nil }
        // Wire field is peer-controlled; clamp before propagating so a
        // hostile peer can't bloat the popover banner with a 10 KB string.
        let clamped = String(request.fromHostname.prefix(RequestToSharePayload.maxHostnameLength))
        return .requestToShare(fromHostname: clamped)
    }

    private func decodeShareResponse(_ payload: Data) -> ScreenShareMessage? {
        guard let request = try? JSONDecoder().decode(TailscreenRequest.self, from: Data(payload))
        else { return nil }
        switch request {
        case .acceptShare:
            return .shareResponse(accepted: true)
        case .declineShare:
            return .shareResponse(accepted: false)
        case .requestToShare:
            // A request payload inside a response frame is malformed; drop it.
            return nil
        }
    }

    private func decodeControlRevoked(_ payload: Data) -> ScreenShareMessage? {
        // An empty payload is tolerated (a bare revoke with no reason).
        guard !payload.isEmpty else { return .controlRevoked(reason: "") }
        guard
            let decoded = try? JSONDecoder().decode(ControlRevokedPayload.self, from: Data(payload))
        else { return .controlRevoked(reason: "") }
        let clamped = String(decoded.reason.prefix(ControlRevokedPayload.maxReasonLength))
        return .controlRevoked(reason: clamped)
    }

    private func decodeInputEvent(_ payload: Data) -> ScreenShareMessage? {
        guard let event = try? JSONDecoder().decode(InputEvent.self, from: Data(payload)) else {
            return nil
        }
        return .inputEvent(event)
    }
}

/// Wire payload for `.controlRevoked`. Its own type so a reason field (and
/// future metadata) can grow without bumping the message-type byte.
struct ControlRevokedPayload: Codable, Sendable {
    /// The reason string is displayed in the viewer's UI; clamp it so a
    /// hostile sharer can't bloat the placard.
    static let maxReasonLength = 128

    let reason: String
}

/// Wire payload for `.requestToShare`. Kept as its own type so the field
/// set can grow (e.g. requested-display ID, message text) without bumping
/// the message-type byte.
struct RequestToSharePayload: Codable, Sendable {
    /// Generous upper bound on a sensible hostname. RFC 1035 caps DNS
    /// labels at 63 chars and FQDNs at 253; we render the hostname in a
    /// 12 pt menubar row where anything past ~64 is already truncated.
    static let maxHostnameLength = 64

    let fromHostname: String
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate func readBigEndian(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(self[index])
        let b1 = UInt32(self[self.index(index, offsetBy: 1)])
        let b2 = UInt32(self[self.index(index, offsetBy: 2)])
        let b3 = UInt32(self[self.index(index, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
