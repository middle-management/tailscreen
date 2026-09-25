import Foundation

/// Pure receiver-report accounting for the viewer's ~1 Hz RTCP-RR-style
/// reports. No I/O, no clock — `RRAccountingTests` covers it on CI.
///
/// The baseline is stored as `extFirst − 1` in signed 64-bit extended-seq
/// space, so the packet establishing it is properly counted in `expected`
/// (avoiding an off-by-one that masked one genuine loss per interval).
/// Arrivals are deduplicated against a sliding bit-window
/// (`dedupeWindowBits`) so a duplicate doesn't inflate `received` and mask
/// further loss — but a served NACK retransmit **is** the first arrival of
/// its seq and still counts, per RFC 3550, so `nextCongestionDecision` sees
/// NACK-recovered loss as recovered.
///
/// The 20-byte wire layout (`ScreenShareControlMessage.encodeReceiverReport`)
/// is untouched; only the reported values became truthful.
public struct RRAccounting: Sendable {
    public init() {}

    /// Sliding dedupe window, in packets, over the extended-seq space. Sized
    /// to cover the retransmit horizon: a served retransmit can legitimately
    /// land thousands of packets behind `highestExt` at high bitrates (1024
    /// was too small at ≈310ms/32Mbps — late fills fell outside the window
    /// and biased fracLostQ8 up, triggering needless bitrate cuts). 4096
    /// packets ≈ 1.2s at that rate.
    public static let dedupeWindowBits = 4096
    private static let wordCount = dedupeWindowBits / 64

    /// Extended sequence number (monotone across 16-bit wraps) of the highest
    /// packet received. −1 until the first packet establishes the baseline.
    private var highestExt: Int64 = -1
    /// Interval baseline: `expected = highestExt − baselineExt`. Starts at
    /// `extFirst − 1` so the baseline packet itself is expected, then advances
    /// to `highestExt` on every `makeReport()`.
    private var baselineExt: Int64 = -1
    /// First-arrival count since the last report.
    private var receivedInInterval = 0
    /// 1024-bit ring over the extended-seq space; a set bit means that seq
    /// already arrived (and was counted) once.
    private var seenBits = [UInt64](repeating: 0, count: RRAccounting.wordCount)

    /// True once at least one packet has been observed.
    public var hasBaseline: Bool { highestExt >= 0 }

    /// Map a 16-bit sequence number into the extended space, choosing the
    /// cycle that lands nearest `near` (wrap-aware). May return a negative
    /// value for a straggler preceding the session start.
    ///
    /// Accepted limitation: a forward jump of more than 32768 packets is
    /// indistinguishable from a backward straggler and gets ignored; the
    /// accounting self-heals on the next in-range packet (the server can't
    /// skip that far within one session today).
    public static func extend(seq: UInt16, near: Int64) -> Int64 {
        let cycleBase = (near >> 16) << 16
        var best = cycleBase + Int64(seq)
        for alt in [best - 65536, best + 65536] where abs(alt - near) < abs(best - near) {
            best = alt
        }
        return best
    }

    /// Feed one received video packet's sequence number.
    public mutating func observe(seq: UInt16) {
        guard highestExt >= 0 else {
            // First packet is both received and expected; baseline sits one
            // before it so `expected = highest − baseline` counts it.
            highestExt = Int64(seq)
            baselineExt = highestExt - 1
            receivedInInterval = 1
            setSeen(highestExt)
            return
        }
        let ext = Self.extend(seq: seq, near: highestExt)
        if ext > highestExt {
            // Clear the window slots the jump exposes so stale bits from a
            // lap ago can't alias as "already seen".
            clearSeenRange(from: highestExt + 1, through: ext)
            highestExt = ext
        }
        // Stragglers older than the window map to a slot a newer seq now owns.
        guard ext >= 0, ext > highestExt - Int64(Self.dedupeWindowBits) else { return }
        if !isSeen(ext) {
            setSeen(ext)
            receivedInInterval += 1
        }
    }

    /// Build the values for one receiver report and reset the interval
    /// accounting. Returns nil until the first packet arrives.
    public mutating func makeReport() -> (fracLostQ8: UInt8, extHighestSeq: UInt32)? {
        guard highestExt >= 0 else { return nil }
        let expected = Int(highestExt - baselineExt)
        var fracQ8 = 0
        if expected > 0 {
            let lost = max(0, expected - receivedInInterval)
            fracQ8 = min(255, lost * 256 / expected)
        }
        // RFC 3550 form (cycles << 16 | highest): low 32 bits of the counter.
        let extForWire = UInt32(truncatingIfNeeded: highestExt)
        baselineExt = highestExt
        receivedInInterval = 0
        return (UInt8(fracQ8), extForWire)
    }

    // MARK: - Sliding-window bitset

    private func slot(_ ext: Int64) -> (word: Int, mask: UInt64) {
        let idx = Int(ext % Int64(Self.dedupeWindowBits))
        return (idx / 64, UInt64(1) << UInt64(idx % 64))
    }

    private func isSeen(_ ext: Int64) -> Bool {
        let s = slot(ext)
        return seenBits[s.word] & s.mask != 0
    }

    private mutating func setSeen(_ ext: Int64) {
        let s = slot(ext)
        seenBits[s.word] |= s.mask
    }

    private mutating func clearSeenRange(from: Int64, through: Int64) {
        guard through >= from else { return }
        if through - from + 1 >= Int64(Self.dedupeWindowBits) {
            // Jump wipes the whole window.
            for i in seenBits.indices {
                seenBits[i] = 0
            }
            return
        }
        var ext = max(from, 0)
        while ext <= through {
            let s = slot(ext)
            seenBits[s.word] &= ~s.mask
            ext += 1
        }
    }
}
