import Foundation

/// Pure single-parity XOR FEC over groups of RTP packets (loss-recovery
/// phase 2 — see `plans/fec-xor-recovery.md`). One parity datagram per group
/// of ≤ `maxGroupSize` media packets lets the receiver reconstruct any *one*
/// lost packet in the group with zero additional RTT; ≥ 2 losses per group
/// fall through to the NACK path.
///
/// **What the parity covers.** Fan-out rewrites only header bytes 2-3 (seq)
/// and 8-11 (SSRC); byte 0 is constant 0x80. Byte 1 (marker | PT) and bytes
/// 4-7 (timestamp) are viewer-invariant but NOT group-invariant — the AU's
/// last packet carries the marker bit — so the parity body is the XOR over
/// each covered packet of:
///
///     [len:2 BE][byte1][timestamp bytes 4..7][payload bytes 12...]
///
/// zero-padded to the longest member (`len` = that packet's total length, so
/// the recovered packet truncates correctly). Recovery XORs the k−1 received
/// members' same fields against the body and reconstructs the missing packet:
/// byte 0 = 0x80, seq = the missing sequence number (known from the gap),
/// SSRC = the stream SSRC (known from any member), byte 1 + timestamp +
/// payload from the XOR. Computing the body on the seq=0/ssrc=0 broadcast
/// templates makes it identical for every viewer — only the datagram's
/// `baseSeq` is rewritten per viewer, the same economics as retransmits.
///
/// Everything here is pure and deterministic (no I/O, no clock), per the
/// extract-the-decision rule — `FECCodecTests` pins it on CI.
public enum FECCodec {
    /// Largest group one parity may cover. Bounded so `count` fits the wire
    /// byte comfortably and double-loss probability per group stays low.
    public static let maxGroupSize = 16
    /// Groups of a single packet are skipped: parity would be pure
    /// duplication, and a single-packet AU is the cheapest possible PLI.
    public static let minGroupSize = 2
    /// XORed per-packet prefix: `[len:2][byte1][timestamp:4]`. A parity body
    /// shorter than this cannot describe any packet — decode rejects it.
    public static let minBodyBytes = 7
    /// Largest legitimate parity body: the XOR prefix plus one full RTP
    /// payload region (the padded body is sized to the longest member, and no
    /// member's payload exceeds the packetizers' MTU budget). `decodeFEC`
    /// rejects anything larger — an oversized body is garbage, not a group.
    public static let maxBodyBytes = minBodyBytes + H264Packetizer.maxPayloadBytes
    /// Body bytes that precede the XORed payload region.
    private static let payloadOffsetInBody = 7

    /// Partition a batch of `templateCount` packets (one access unit — groups
    /// must never span batches, see the throttled-viewer seq-contiguity rule)
    /// into `⌈count/groupSize⌉` **balanced** consecutive runs (sizes differ by
    /// at most one). Balancing instead of greedy-chunking means a batch one
    /// past a group boundary (e.g. 11 with N = 10) splits 6+5 rather than
    /// 10+1: the same parity overhead, but no sub-`minGroupSize` remainder is
    /// ever left uncovered — crucially the AU's **marker packet** always sits
    /// inside a covered group. Batches smaller than `minGroupSize` get no
    /// parity (a single-packet AU is the cheapest possible PLI).
    public static func groupRanges(
        templateCount: Int, groupSize: Int, minGroupSize: Int = FECCodec.minGroupSize
    ) -> [Range<Int>] {
        guard groupSize >= minGroupSize, templateCount >= minGroupSize else { return [] }
        let cap = min(groupSize, maxGroupSize)
        var groups = (templateCount + cap - 1) / cap  // ⌈count/cap⌉
        // Degenerate tiny caps (cap < 2×minGroupSize) can balance below
        // minGroupSize; shrink the group count until every group is legal.
        // Sizes then exceed `cap` slightly but stay far under the wire's
        // `maxGroupSize` (only reachable for cap = 2).
        while groups > 1 && templateCount / groups < minGroupSize {
            groups -= 1
        }
        let base = templateCount / groups
        let extra = templateCount % groups
        var out: [Range<Int>] = []
        out.reserveCapacity(groups)
        var start = 0
        for index in 0..<groups {
            let size = base + (index < extra ? 1 : 0)
            out.append(start..<(start + size))
            start += size
        }
        return out
    }

    /// Compute the XOR parity body over one group of packets (full RTP
    /// packets — templates or received copies; the covered fields are
    /// identical either way). Empty result if the group is degenerate
    /// (fewer than `minGroupSize` members or any member shorter than an
    /// RTP header).
    public static func parityBody(for packets: ArraySlice<Data>) -> Data {
        guard packets.count >= minGroupSize else { return Data() }
        var maxLen = 0
        for packet in packets {
            guard packet.count >= RTPHeader.size else { return Data() }
            maxLen = max(maxLen, packet.count)
        }
        var body = Data(count: payloadOffsetInBody + (maxLen - RTPHeader.size))
        for packet in packets {
            xorPacket(packet, into: &body)
        }
        return body
    }

    /// XOR one packet's covered fields into `body` (in place). Shared by the
    /// parity compute (XOR of all members) and the recovery solve (XOR of the
    /// received members against the parity body). Uses raw-buffer access —
    /// this runs on the broadcast path once per keyframe packet (megabytes
    /// per keyframe), where per-byte `Data` subscripting is real overhead.
    /// `withUnsafeBytes` on a `Data` slice exposes the slice's own bytes
    /// zero-based, so both full `Data`s and re-based slices are safe here.
    private static func xorPacket(_ packet: Data, into body: inout Data) {
        let len = UInt16(truncatingIfNeeded: packet.count)
        let payloadLen = packet.count - RTPHeader.size
        body.withUnsafeMutableBytes { (bodyRaw: UnsafeMutableRawBufferPointer) in
            packet.withUnsafeBytes { (packetRaw: UnsafeRawBufferPointer) in
                let out = bodyRaw.bindMemory(to: UInt8.self)
                let pkt = packetRaw.bindMemory(to: UInt8.self)
                out[0] ^= UInt8((len >> 8) & 0xFF)
                out[1] ^= UInt8(len & 0xFF)
                out[2] ^= pkt[1]
                for i in 0..<4 {
                    out[3 + i] ^= pkt[4 + i]
                }
                let copyLen = min(payloadLen, out.count - payloadOffsetInBody)
                guard copyLen > 0 else { return }
                for i in 0..<copyLen {
                    out[payloadOffsetInBody + i] ^= pkt[RTPHeader.size + i]
                }
            }
        }
    }

    /// Reconstruct the single missing packet of a group from the k−1 received
    /// `members` and the group's parity `body`. `missingSeq` and `ssrc` come
    /// from the receiver's own gap tracking / any member's header. Returns
    /// nil on any inconsistency (member shorter than an RTP header, body too
    /// short, recovered length out of the body's range, or a recovered length
    /// below the RTP header size) — malformed parity must never emit a torn
    /// packet into the depacketizer.
    public static func recover(missingSeq: UInt16, ssrc: UInt32, members: [Data], body: Data) -> Data? {
        guard body.count >= minBodyBytes else { return nil }
        for member in members where member.count < RTPHeader.size {
            return nil
        }
        for member in members where member.count - RTPHeader.size > body.count - payloadOffsetInBody {
            // A member's payload exceeds the parity's padded region: this
            // parity can't have covered it — reject rather than mis-solve.
            return nil
        }
        var solved = body
        for member in members {
            xorPacket(member, into: &solved)
        }

        let base = solved.startIndex
        let recoveredLen = Int(solved.readBE(UInt16.self, at: base))
        guard recoveredLen >= RTPHeader.size,
            recoveredLen - RTPHeader.size <= solved.count - payloadOffsetInBody
        else { return nil }

        var packet = Data(capacity: recoveredLen)
        packet.append(0x80)  // V=2, P=0, X=0, CC=0 — constant across our packetizers
        packet.append(solved[base + 2])  // marker | payload type
        packet.appendBE(missingSeq)
        packet.append(contentsOf: solved[(base + 3)..<(base + 7)])  // timestamp
        packet.appendBE(ssrc)
        let payloadLen = recoveredLen - RTPHeader.size
        if payloadLen > 0 {
            let payloadStart = solved.index(base, offsetBy: payloadOffsetInBody)
            let payloadEnd = solved.index(payloadStart, offsetBy: payloadLen)
            packet.append(solved[payloadStart..<payloadEnd])
        }
        return packet
    }
}
