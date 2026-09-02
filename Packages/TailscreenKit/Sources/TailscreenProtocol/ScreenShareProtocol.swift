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
///     .metadataRequest (0x0B) — peer→peer
///         "describe yourself" — drives the peer list's sharing-status
///         filter. Empty payload; answered with `.metadataResponse` on the
///         SAME TCP connection (like `.shareResponse` — no dial-back). Old
///         peers drop the unknown byte, so the requester just times out
///         and the peer reads as status-unknown.
///     .metadataResponse (0x0C) — request receiver→requester
///         payload = JSON-encoded ``TailscreenMetadata`` (share name,
///         resolution, `isSharing`). Exposes nothing the tailnet can't
///         already see (the hostname is in the netmap) plus the share
///         state a viewer would learn by connecting.
///     .mediaDatagram  (0x0D)  — both directions
///         one raw UDP datagram carried over the stream (spec §2.2, the
///         reliable-transport profile for viewers without usable UDP).
///         The ONE non-JSON payload on this channel: hand it to the
///         datagram demultiplexer exactly as if it had arrived on the
///         UDP socket (first-byte classification, TS-GEN-020).
public enum ScreenShareMessage {
    case annotation(AnnotationOp)
    case requestToShare(fromHostname: String)
    case shareResponse(accepted: Bool)
    case controlRequest
    case controlGranted
    case controlRevoked(reason: String)
    case inputEvent(InputEvent)
    case controlReleased
    case metadataRequest
    case metadataResponse(TailscreenMetadata)
    case mediaDatagram(Data)

    public static let headerSize = 5

    /// Hard ceiling on a single frame's payload. Every legitimate payload
    /// (annotation op, input event, request/response JSON) is well under a
    /// kilobyte; the cap stops a hostile peer from advertising a 4 GiB length
    /// and slow-streaming bytes to grow the parser's buffer without bound —
    /// especially now that a privileged `.inputEvent` consumer rides this
    /// channel. A frame declaring more than this poisons the parser (the
    /// stream is unrecoverable) and the receive loop closes the connection.
    public static let maxPayloadLength = 1 << 20  // 1 MiB

    /// `CaseIterable` so `WireByteRegistryTests` can enumerate the live cases
    /// and hold them against the pinned registry table (exhaustiveness leg).
    /// 0x00–0x02 are historical/reserved — don't fill the gap without
    /// checking what shipped peers do with those bytes.
    public enum MessageType: UInt8, CaseIterable {
        case annotation = 0x03
        case requestToShare = 0x04
        case shareResponse = 0x05
        case controlRequest = 0x06
        case controlGranted = 0x07
        case controlRevoked = 0x08
        case inputEvent = 0x09
        // 0x0A–0x0C are also used by the UDP control byte space
        // (NACK/RR/PING); this is the disjoint TCP message-type space, so
        // they're free here — see WireByteRegistryTests'
        // testTCPAndUDPSpacesAreDisjointOnPurpose.
        case controlReleased = 0x0A
        case metadataRequest = 0x0B
        case metadataResponse = 0x0C
        case mediaDatagram = 0x0D
    }

    /// Serialize this message as a wire-format packet (header + payload).
    public func encode() -> Data {
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
        case .metadataRequest:
            return Self.frame(type: .metadataRequest, payload: Data())
        case .metadataResponse(let metadata):
            let payload = (try? JSONEncoder().encode(metadata)) ?? Data()
            return Self.frame(type: .metadataResponse, payload: payload)
        case .mediaDatagram(let datagram):
            return Self.frame(type: .mediaDatagram, payload: datagram)
        }
    }

    private static func frame(type: MessageType, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(type.rawValue)
        out.appendBE(UInt32(payload.count))
        out.append(payload)
        return out
    }
}

/// Incremental parser. Feed bytes as they arrive; ``next()`` returns whole messages.
public struct ScreenShareMessageParser {
    public init() {}

    private var buffer = Data()
    /// Set once a frame declares a payload longer than
    /// ``ScreenShareMessage/maxPayloadLength`` — the stream is unrecoverable
    /// (we can't know where the next frame starts), so ``next()`` returns nil
    /// forever and the receive loop should close the connection.
    private(set) public var isCorrupt = false

    public mutating func append(_ data: Data) {
        // Once poisoned, stop buffering — don't let a hostile peer keep
        // growing memory after an oversized-length rejection.
        guard !isCorrupt else { return }
        buffer.append(data)
    }

    public mutating func next() -> ScreenShareMessage? {
        // A loop rather than early returns on decode failure: a frame whose
        // payload fails to decode is discarded and parsing continues with the
        // next frame (TS-TCP-008). Returning nil for a bad payload made every
        // receive loop's `while let` drain treat "bad frame" as "need more
        // bytes" — messages already buffered behind the bad frame sat
        // undelivered until further traffic happened to arrive.
        while true {
            guard !isCorrupt else { return nil }
            guard buffer.count >= ScreenShareMessage.headerSize else { return nil }

            let rawType = buffer[buffer.startIndex]
            let lengthStart = buffer.index(buffer.startIndex, offsetBy: 1)
            let length = Int(buffer.readBE(UInt32.self, at: lengthStart))
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
                // Unknown type: payload already consumed, drop it (TS-TCP-003).
                continue
            }

            let message: ScreenShareMessage?
            switch type {
            case .annotation:
                message = decodeAnnotation(payload)
            case .requestToShare:
                message = decodeRequestToShare(payload)
            case .shareResponse:
                message = decodeShareResponse(payload)
            case .controlRequest:
                message = .controlRequest
            case .controlGranted:
                message = .controlGranted
            case .controlRevoked:
                message = decodeControlRevoked(payload)
            case .inputEvent:
                message = decodeInputEvent(payload)
            case .controlReleased:
                message = .controlReleased
            case .metadataRequest:
                message = .metadataRequest
            case .metadataResponse:
                message = decodeMetadataResponse(payload)
            case .mediaDatagram:
                // Raw datagram bytes, deliberately not decoded here — the
                // consumer runs the first-byte demultiplex (TS-GEN-020).
                // An empty payload is no datagram at all (TS-STM-001, the
                // frame shape of TS-GEN-022): drop it like any payload
                // that fails to decode (TS-TCP-008).
                message = payload.isEmpty ? nil : .mediaDatagram(Data(payload))
            }
            if let message {
                return message
            }
            // Known type, undecodable payload: dropped, keep parsing.
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

    private func decodeMetadataResponse(_ payload: Data) -> ScreenShareMessage? {
        guard
            let metadata = try? JSONDecoder().decode(TailscreenMetadata.self, from: Data(payload))
        else { return nil }
        // The strings are peer-controlled and rendered in the popover's
        // peer rows; clamp before propagating so a hostile peer can't
        // bloat the UI (same rule as `.requestToShare`'s hostname).
        let clamped = TailscreenMetadata(
            shareName: String(metadata.shareName.prefix(TailscreenMetadata.maxDisplayStringLength)),
            hostname: String(metadata.hostname.prefix(TailscreenMetadata.maxDisplayStringLength)),
            screenResolution: metadata.screenResolution,
            isSharing: metadata.isSharing,
            timestamp: metadata.timestamp,
            videoCodec: metadata.videoCodec)
        return .metadataResponse(clamped)
    }

    private func decodeInputEvent(_ payload: Data) -> ScreenShareMessage? {
        // INVARIANT: the stock JSONDecoder's default
        // `nonConformingFloatDecodingStrategy = .throw` is load-bearing here —
        // it rejects `NaN` / `Infinity` / `-Infinity` tokens and out-of-range
        // literals like `1e999` in the coordinate fields, which is the first
        // line of defense against a NaN reaching the injector's coordinate
        // math. Pinned by `ScreenShareProtocolTests`; don't "improve" this
        // decoder with `.convertFromString` without reading those tests.
        // (`RemoteControlMapping.globalPoint` also defends itself now, but
        // rejecting the frame outright is still the right call.)
        guard let event = try? JSONDecoder().decode(InputEvent.self, from: Data(payload)) else {
            return nil
        }
        return .inputEvent(event)
    }
}

/// Wire payload for `.controlRevoked`. Its own type so a reason field (and
/// future metadata) can grow without bumping the message-type byte.
public struct ControlRevokedPayload: Codable, Sendable {
    /// The reason string is displayed in the viewer's UI; clamp it so a
    /// hostile sharer can't bloat the placard.
    public static let maxReasonLength = 128

    public let reason: String
}

/// Wire payload for `.requestToShare`. Kept as its own type so the field
/// set can grow (e.g. requested-display ID, message text) without bumping
/// the message-type byte.
public struct RequestToSharePayload: Codable, Sendable {
    /// Generous upper bound on a sensible hostname. RFC 1035 caps DNS
    /// labels at 63 chars and FQDNs at 253; we render the hostname in a
    /// 12 pt menubar row where anything past ~64 is already truncated.
    public static let maxHostnameLength = 64

    public let fromHostname: String
}

// `appendBE`/`readBE` live in `DataBigEndian.swift`, shared module-wide
// (this file's copies were spelled `appendBigEndian`/`readBigEndian`).
