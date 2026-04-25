import Foundation

/// RTP wire format used between the screen-share server and viewers (RFC 3550 +
/// RFC 6184 H.264 payload). The same UDP socket also carries small "control"
/// datagrams from the viewer back to the server (HELLO, KEEPALIVE, BYE, PLI).
/// We disambiguate by the first byte: real RTP packets are V=2, so byte 0 is
/// always in the range 0x80-0xBF; control packets use 0x00-0x7F.
///
/// Single byte at offset 0 of every datagram on the wire:
///
///     0x00 (HELLO)     viewer → server: register me, please send IDR
///     0x01 (KEEPALIVE) viewer → server: I'm still here
///     0x02 (BYE)       viewer → server: drop me from the fan-out set
///     0x03 (PLI)       viewer → server: I lost something, please send IDR
///     0x80..0xBF       RTP packet (V=2)
enum ScreenShareControlMessage: UInt8 {
    case hello = 0x00
    case keepalive = 0x01
    case bye = 0x02
    case pli = 0x03

    static func encode(_ kind: ScreenShareControlMessage) -> Data {
        Data([kind.rawValue])
    }

    static func decode(_ data: Data) -> ScreenShareControlMessage? {
        guard let first = data.first, let kind = ScreenShareControlMessage(rawValue: first) else { return nil }
        return kind
    }

    /// True if the first byte of `data` is a non-RTP control packet rather
    /// than an RTP packet (V=2, MSB pattern 10xx_xxxx).
    static func looksLikeControl(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return (first & 0xC0) != 0x80
    }
}

/// 12-byte fixed RTP header (no CSRC list, no extension).
struct RTPHeader {
    static let size = 12
    static let h264PayloadType: UInt8 = 96  // dynamic PT, RFC 6184 default
    static let clockHz: UInt32 = 90_000

    var marker: Bool
    var payloadType: UInt8
    var sequenceNumber: UInt16
    var timestamp: UInt32
    var ssrc: UInt32

    func encode(into buffer: inout Data) {
        // V=2, P=0, X=0, CC=0
        buffer.append(0x80)
        buffer.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        buffer.appendBE(sequenceNumber)
        buffer.appendBE(timestamp)
        buffer.appendBE(ssrc)
    }

    /// Parse the fixed RTP header. Returns the header plus the offset at
    /// which the payload starts (skipping CSRC list and extension if any).
    static func decode(from data: Data) -> (header: RTPHeader, payloadOffset: Int)? {
        guard data.count >= size else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        guard (b0 & 0xC0) == 0x80 else { return nil }  // require V=2

        let csrcCount = Int(b0 & 0x0F)
        let hasExt = (b0 & 0x10) != 0
        let marker = (b1 & 0x80) != 0
        let pt = b1 & 0x7F

        let seq = data.readBE(UInt16.self, at: data.startIndex + 2)
        let ts = data.readBE(UInt32.self, at: data.startIndex + 4)
        let ssrc = data.readBE(UInt32.self, at: data.startIndex + 8)

        var offset = size + csrcCount * 4
        if hasExt {
            // [profile:2][length:2 in 32-bit words][... extension ...]
            guard data.count >= offset + 4 else { return nil }
            let extLen = Int(data.readBE(UInt16.self, at: data.startIndex + offset + 2))
            offset += 4 + extLen * 4
        }
        guard data.count >= offset else { return nil }

        let header = RTPHeader(
            marker: marker,
            payloadType: pt,
            sequenceNumber: seq,
            timestamp: ts,
            ssrc: ssrc
        )
        return (header, offset)
    }
}

/// Splits an AVCC-formatted access unit into a sequence of length-prefixed
/// NAL units. Each entry is the raw NAL bytes (NAL header + RBSP), no length
/// prefix.
enum AVCCParser {
    static func nalUnits(from avcc: Data, lengthSize: Int = 4) -> [Data] {
        var nals: [Data] = []
        var i = avcc.startIndex
        while i < avcc.endIndex {
            guard avcc.distance(from: i, to: avcc.endIndex) >= lengthSize else { break }
            var len = 0
            for k in 0..<lengthSize {
                len = (len << 8) | Int(avcc[avcc.index(i, offsetBy: k)])
            }
            let nalStart = avcc.index(i, offsetBy: lengthSize)
            guard avcc.distance(from: nalStart, to: avcc.endIndex) >= len else { break }
            let nalEnd = avcc.index(nalStart, offsetBy: len)
            nals.append(Data(avcc[nalStart..<nalEnd]))
            i = nalEnd
        }
        return nals
    }
}

/// RFC 6184 H.264 packetizer. Single NAL mode for small NALs, FU-A for
/// anything that wouldn't fit in one MTU. STAP-A is intentionally not used
/// — keeping the format flat makes the depacketizer trivial.
enum H264Packetizer {
    /// Max bytes of RTP *payload* per packet (excludes the 12-byte RTP header).
    /// Tailscale's WireGuard tunnel typically uses MTU 1280; subtract IPv6+UDP
    /// (40+8) and RTP header (12), leaving ~1220. We use 1100 for headroom.
    static let maxPayloadBytes = 1100

    /// Packetize one access unit's NAL units into RTP packets ready to send.
    /// Sequence numbers run from `startSequence` (incrementing by 1 per
    /// returned packet); the marker bit is set on the last packet only.
    static func packetize(
        nals: [Data],
        timestamp: UInt32,
        ssrc: UInt32,
        startSequence: UInt16
    ) -> [Data] {
        // Build the list of payload chunks first, then walk it once to write
        // RTP headers. Two-pass keeps the marker-bit-on-last logic obvious.
        var chunks: [Data] = []
        for nal in nals {
            guard let header = nal.first else { continue }
            if nal.count <= maxPayloadBytes {
                chunks.append(nal)  // Single NAL: payload IS the NAL
            } else {
                appendFUA(nal: nal, header: header, into: &chunks)
            }
        }

        var packets: [Data] = []
        packets.reserveCapacity(chunks.count)
        var seq = startSequence
        for (index, payload) in chunks.enumerated() {
            let isLast = index == chunks.count - 1
            var packet = Data(capacity: RTPHeader.size + payload.count)
            let header = RTPHeader(
                marker: isLast,
                payloadType: RTPHeader.h264PayloadType,
                sequenceNumber: seq,
                timestamp: timestamp,
                ssrc: ssrc
            )
            header.encode(into: &packet)
            packet.append(payload)
            packets.append(packet)
            seq &+= 1
        }
        return packets
    }

    /// RFC 6184 §5.8 FU-A fragmentation. Splits the NAL body (excluding the
    /// 1-byte NAL header) into fragments; each fragment carries a 2-byte
    /// FU header (FU indicator + FU header) followed by the fragment bytes.
    private static func appendFUA(nal: Data, header: UInt8, into chunks: inout [Data]) {
        let nri = header & 0x60
        let nalType = header & 0x1F
        let fuIndicator: UInt8 = nri | 28  // type 28 = FU-A
        let body = nal.dropFirst()

        // Reserve 2 bytes per fragment for the FU header pair.
        let fragSize = maxPayloadBytes - 2
        var offset = body.startIndex
        var first = true
        while offset < body.endIndex {
            let remaining = body.distance(from: offset, to: body.endIndex)
            let take = min(fragSize, remaining)
            let end = body.index(offset, offsetBy: take)
            let isLast = end == body.endIndex

            var fuHeader: UInt8 = nalType
            if first { fuHeader |= 0x80 }       // S bit
            if isLast { fuHeader |= 0x40 }      // E bit

            var chunk = Data(capacity: 2 + take)
            chunk.append(fuIndicator)
            chunk.append(fuHeader)
            chunk.append(body[offset..<end])
            chunks.append(chunk)

            offset = end
            first = false
        }
    }
}

/// Stateful receiver that reassembles RTP packets back into AVCC-formatted
/// access units (length-prefixed NAL units, exactly the shape `VideoDecoder`
/// expects). Detects packet loss inside a frame and drops the partial AU so
/// the decoder never sees a torn frame; the caller is expected to send a PLI
/// in response so the encoder issues a fresh IDR.
final class H264Depacketizer {
    /// Output: one assembled access unit, plus whether it contains an IDR.
    /// `lostBeforeThisAU` is true if we observed a sequence-number gap or had
    /// to drop the in-progress AU due to loss; the caller uses this to
    /// trigger a keyframe request.
    struct AccessUnit {
        let avcc: Data
        let containsIDR: Bool
        let timestamp: UInt32
        let lostBeforeThisAU: Bool
    }

    private var ssrc: UInt32?
    private var expectedSeq: UInt16?
    private var currentTimestamp: UInt32?
    private var currentAU: Data = Data()
    private var currentHasIDR: Bool = false
    private var currentAUCorrupted: Bool = false
    private var fuBuffer: Data = Data()
    private var fuNALHeader: UInt8 = 0
    private var inFU: Bool = false
    private var pendingLossSignal: Bool = false

    /// Feed one received RTP packet. Returns a completed AU once the marker
    /// bit (or a timestamp change) signals end-of-frame; nil otherwise.
    func ingest(_ packet: Data) -> AccessUnit? {
        guard let (header, payloadOffset) = RTPHeader.decode(from: packet) else { return nil }
        guard header.payloadType == RTPHeader.h264PayloadType else { return nil }

        // Lock onto the first SSRC we see; ignore packets from a different
        // session (could happen if the sender restarts).
        if let known = ssrc, known != header.ssrc {
            reset()
            ssrc = header.ssrc
        } else if ssrc == nil {
            ssrc = header.ssrc
        }

        // Sequence number gap detection. We don't reorder — a single missing
        // packet pollutes the current AU and we drop it.
        if let expected = expectedSeq, header.sequenceNumber != expected {
            // Treat any deviation (loss or reorder) as loss for this AU.
            currentAUCorrupted = true
            pendingLossSignal = true
            inFU = false
            fuBuffer.removeAll(keepingCapacity: true)
        }
        expectedSeq = header.sequenceNumber &+ 1

        // Timestamp change without a marker means the previous AU's marker
        // packet was lost. Discard whatever we accumulated and start fresh.
        if let prevTs = currentTimestamp, prevTs != header.timestamp {
            currentAUCorrupted = true
            currentAU.removeAll(keepingCapacity: true)
            currentHasIDR = false
            inFU = false
            fuBuffer.removeAll(keepingCapacity: true)
            pendingLossSignal = true
        }
        currentTimestamp = header.timestamp

        let payload = packet[packet.index(packet.startIndex, offsetBy: payloadOffset)..<packet.endIndex]
        if payload.isEmpty {
            currentAUCorrupted = true
        } else {
            handlePayload(Data(payload))
        }

        if header.marker {
            return flushAU(timestamp: header.timestamp)
        }
        return nil
    }

    private func handlePayload(_ payload: Data) {
        let nalHeader = payload[payload.startIndex]
        let nalType = nalHeader & 0x1F

        switch nalType {
        case 1...23:
            // Single NAL packet: payload IS the complete NAL.
            appendNAL(payload)
        case 28:
            // FU-A: payload is [FU indicator][FU header][fragment...].
            guard payload.count >= 2 else {
                currentAUCorrupted = true
                return
            }
            let fuIndicator = payload[payload.startIndex]
            let fuHeader = payload[payload.startIndex + 1]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x1F
            let fragStart = payload.index(payload.startIndex, offsetBy: 2)
            let fragment = payload[fragStart..<payload.endIndex]

            if isStart {
                fuBuffer.removeAll(keepingCapacity: true)
                // Reconstruct original NAL header: F+NRI from FU indicator, type from FU header.
                fuNALHeader = (fuIndicator & 0xE0) | originalType
                fuBuffer.append(fuNALHeader)
                fuBuffer.append(fragment)
                inFU = true
            } else if inFU {
                fuBuffer.append(fragment)
            } else {
                // Got a middle/end fragment without start — we missed packets.
                currentAUCorrupted = true
                return
            }

            if isEnd && inFU {
                appendNAL(fuBuffer)
                fuBuffer.removeAll(keepingCapacity: true)
                inFU = false
            }
        default:
            // STAP-A (24), MTAP (26-27), FU-B (29), reserved — we never emit
            // these, so unexpected. Mark AU corrupted rather than guess.
            currentAUCorrupted = true
        }
    }

    private func appendNAL(_ nal: Data) {
        let nalType = nal.first.map { $0 & 0x1F } ?? 0
        if nalType == 5 { currentHasIDR = true }
        // AVCC: 4-byte big-endian length prefix then NAL bytes.
        let len = UInt32(nal.count)
        currentAU.appendBE(len)
        currentAU.append(nal)
    }

    private func flushAU(timestamp: UInt32) -> AccessUnit? {
        let wasCorrupted = currentAUCorrupted || currentAU.isEmpty
        let lostBefore = pendingLossSignal
        let avcc = currentAU
        let hasIDR = currentHasIDR

        currentAU = Data()
        currentHasIDR = false
        currentAUCorrupted = false
        inFU = false
        fuBuffer.removeAll(keepingCapacity: true)
        currentTimestamp = nil

        if wasCorrupted {
            // Drop the AU but keep the loss flag latched so the next clean
            // AU still carries it — the caller uses that to drive PLI.
            return nil
        }
        pendingLossSignal = false
        return AccessUnit(
            avcc: avcc,
            containsIDR: hasIDR,
            timestamp: timestamp,
            lostBeforeThisAU: lostBefore
        )
    }

    /// Discard all in-flight state. Called on SSRC change.
    private func reset() {
        expectedSeq = nil
        currentTimestamp = nil
        currentAU.removeAll(keepingCapacity: true)
        currentHasIDR = false
        currentAUCorrupted = false
        fuBuffer.removeAll(keepingCapacity: true)
        inFU = false
        pendingLossSignal = false
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readBE(_: UInt16.Type, at index: Data.Index) -> UInt16 {
        let b0 = UInt16(self[index])
        let b1 = UInt16(self[self.index(index, offsetBy: 1)])
        return (b0 << 8) | b1
    }

    func readBE(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(self[index])
        let b1 = UInt32(self[self.index(index, offsetBy: 1)])
        let b2 = UInt32(self[self.index(index, offsetBy: 2)])
        let b3 = UInt32(self[self.index(index, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
