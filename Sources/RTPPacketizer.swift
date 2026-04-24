import Foundation

/// Standards-compliant RTP (RFC 3550) + H.264 payload format (RFC 6184)
/// packetizer. Takes an AVCC-formatted access unit (length-prefixed NAL
/// units, which is what VideoToolbox emits) and produces an ordered array
/// of UDP payloads ready to hand to ``UDPMediaTransport``.
///
/// Only two payload modes are implemented: **Single NAL Unit** for small
/// NALs, and **FU-A fragmentation** for NALs larger than the MTU budget.
/// Everything real-world sees one of those two. STAP-A aggregation and the
/// interleaved modes are deliberately omitted — nobody uses them and they
/// make the code substantially more complex.
///
/// Wire interop: a capture of this stream should be playable in VLC /
/// FFmpeg / Wireshark once you point it at `rtp://<tailnet-ip>:7448` with
/// an SDP describing payload type 96 @ 90 kHz + SPS/PPS. That's the
/// primary "industry practice" win we're buying with this code.
enum RTPConstants {
    /// Max RTP-packet payload (header + RTP payload). Tailscale's WireGuard
    /// default MTU is 1280 bytes; we leave ~80 bytes of slack for IPv6 +
    /// UDP headers.
    static let maxDatagramBytes = 1200
    /// Dynamic payload type for H.264.
    static let payloadType: UInt8 = 96
    /// 90 kHz media clock is the convention for H.264 in RTP.
    static let clockRateHz: UInt32 = 90_000
}

/// RTP header = 12 bytes (no extensions, no CSRCs).
private let rtpHeaderBytes = 12
/// Budget for the payload carried inside one RTP packet.
private let maxRTPPayloadBytes = RTPConstants.maxDatagramBytes - rtpHeaderBytes

final class RTPPacketizer: @unchecked Sendable {
    private let ssrc: UInt32
    private var sequenceNumber: UInt16

    init(ssrc: UInt32 = UInt32.random(in: .min ... .max),
         initialSequence: UInt16 = UInt16.random(in: .min ... .max)) {
        self.ssrc = ssrc
        self.sequenceNumber = initialSequence
    }

    /// Convert a VideoToolbox AVCC access unit into a series of RTP packets.
    ///
    /// - Parameters:
    ///   - accessUnit: concatenation of `[4 BE length][NAL bytes]` units.
    ///   - rtpTimestamp: 32-bit, 90 kHz clock. Same value for every packet
    ///     produced by a single call (they are all pieces of one frame).
    /// - Returns: ordered array of UDP datagrams. Last packet has the RTP
    ///   marker bit set (end-of-frame hint for the depacketizer).
    func packetize(accessUnit: Data, rtpTimestamp: UInt32) -> [Data] {
        let nals = Self.splitAVCC(accessUnit)
        guard !nals.isEmpty else { return [] }

        var packets: [Data] = []
        for (idx, nal) in nals.enumerated() {
            let isLastNAL = (idx == nals.count - 1)
            if nal.count <= maxRTPPayloadBytes {
                packets.append(makeSingleNAL(nal: nal,
                                             timestamp: rtpTimestamp,
                                             marker: isLastNAL))
            } else {
                let fuPackets = makeFUA(nal: nal,
                                        timestamp: rtpTimestamp,
                                        markerOnLast: isLastNAL)
                packets.append(contentsOf: fuPackets)
            }
        }
        return packets
    }

    // MARK: - Single NAL

    private func makeSingleNAL(nal: Data, timestamp: UInt32, marker: Bool) -> Data {
        var pkt = Data(capacity: rtpHeaderBytes + nal.count)
        writeRTPHeader(into: &pkt, timestamp: timestamp, marker: marker)
        pkt.append(nal)
        return pkt
    }

    // MARK: - FU-A

    private func makeFUA(nal: Data, timestamp: UInt32, markerOnLast: Bool) -> [Data] {
        // NAL header byte: F(1) NRI(2) Type(5).
        let nalHeader = nal[nal.startIndex]
        let f_nri = nalHeader & 0b1110_0000          // F + NRI preserved
        let originalType = nalHeader & 0b0001_1111   // NAL type
        let fuIndicator = f_nri | 28                 // Type 28 = FU-A

        let payloadStart = nal.index(after: nal.startIndex)
        let body = nal[payloadStart...]              // NAL without the 1-byte header

        // Budget per fragment: max payload minus 2 bytes for FU indicator + FU header.
        let perFragment = maxRTPPayloadBytes - 2

        var packets: [Data] = []
        var offset = body.startIndex
        while offset < body.endIndex {
            let remaining = body.distance(from: offset, to: body.endIndex)
            let chunkLen = min(perFragment, remaining)
            let chunkEnd = body.index(offset, offsetBy: chunkLen)
            let isStart = (offset == body.startIndex)
            let isEnd = (chunkEnd == body.endIndex)

            var fuHeader = originalType
            if isStart { fuHeader |= 0b1000_0000 }   // S
            if isEnd   { fuHeader |= 0b0100_0000 }   // E

            let markerBit = isEnd && markerOnLast

            var pkt = Data(capacity: rtpHeaderBytes + 2 + chunkLen)
            writeRTPHeader(into: &pkt, timestamp: timestamp, marker: markerBit)
            pkt.append(fuIndicator)
            pkt.append(fuHeader)
            pkt.append(body[offset..<chunkEnd])
            packets.append(pkt)

            offset = chunkEnd
        }
        return packets
    }

    // MARK: - RTP header

    private func writeRTPHeader(into data: inout Data, timestamp: UInt32, marker: Bool) {
        // Byte 0: V=2, P=0, X=0, CC=0  →  0b10_0_0_0000 = 0x80
        data.append(0x80)
        // Byte 1: M (1 bit) | PT (7 bits)
        let markerBit: UInt8 = marker ? 0x80 : 0x00
        data.append(markerBit | (RTPConstants.payloadType & 0x7F))
        // Bytes 2-3: sequence number (BE)
        let seq = sequenceNumber
        sequenceNumber = sequenceNumber &+ 1
        data.appendBigEndian(seq)
        // Bytes 4-7: timestamp (BE)
        data.appendBigEndian(timestamp)
        // Bytes 8-11: SSRC (BE)
        data.appendBigEndian(ssrc)
    }

    // MARK: - AVCC split

    /// Walk an AVCC access unit and return the NAL units without their
    /// 4-byte length prefixes.
    static func splitAVCC(_ accessUnit: Data) -> [Data] {
        var nals: [Data] = []
        var idx = accessUnit.startIndex
        while idx < accessUnit.endIndex {
            let remaining = accessUnit.distance(from: idx, to: accessUnit.endIndex)
            guard remaining >= 4 else { break }
            let length = Int(accessUnit.readBigEndian(UInt32.self, at: idx))
            let nalStart = accessUnit.index(idx, offsetBy: 4)
            guard accessUnit.distance(from: nalStart, to: accessUnit.endIndex) >= length else { break }
            let nalEnd = accessUnit.index(nalStart, offsetBy: length)
            if length > 0 {
                nals.append(Data(accessUnit[nalStart..<nalEnd]))
            }
            idx = nalEnd
        }
        return nals
    }
}

/// Translate the server's `mach_absolute_time` (nanoseconds since boot) into
/// a 32-bit RTP timestamp at 90 kHz. Monotonic; wraps after ~13 hours at
/// 90 kHz, which RTP is designed for.
enum RTPClock {
    static func timestamp(fromUptimeNanoseconds ns: UInt64) -> UInt32 {
        // 90_000 ticks/sec ÷ 1e9 ns/sec = 9/100_000. Multiply first to keep
        // precision, then divide; truncation is fine for a 32-bit wrap clock.
        let ticks = (ns / 1_000_000_000) * UInt64(RTPConstants.clockRateHz)
                  + ((ns % 1_000_000_000) * UInt64(RTPConstants.clockRateHz)) / 1_000_000_000
        return UInt32(truncatingIfNeeded: ticks)
    }
}
