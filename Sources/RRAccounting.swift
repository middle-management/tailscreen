import Foundation

/// Pure receiver-report accounting for the viewer's ~1 Hz RTCP-RR-style
/// reports (the extract-the-decision pattern — no I/O, no clock, so
/// `RRAccountingTests` covers it on CI).
///
/// Replaces the previous inline bookkeeping in `TailscaleScreenShareClient`,
/// fixing two defects in the move:
///
/// - **Baseline off-by-one.** The packet that established the baseline was
///   counted in `received` but not in `expected` (`expected = extHighest −
///   base` with `base = firstSeq`), so the first interval reported
///   `expected = N−1, received = N` and one genuine loss was masked by the
///   `max(0, …)` clamp. The baseline is now stored as `extFirst − 1` in a
///   signed 64-bit extended-sequence space (no `UInt32` underflow when the
///   first seq is 0), so N packets with no loss yield
///   `expected == received == N`.
/// - **Duplicate inflation.** Duplicates (and re-deliveries of already
///   counted seqs) incremented `received` every time, masking further loss
///   exactly when the congestion controller most needs truth. Arrivals are
///   now deduplicated against a sliding bit-window over the extended
///   sequence space (`dedupeWindowBits`, sized to the server's retransmit
///   horizon): only the *first* arrival of a seq counts. A served NACK retransmit **is** the first
///   arrival of its seq and still counts as received — precisely RFC 3550's
///   intent, and what lets `nextCongestionDecision` see NACK-recovered loss
///   as recovered.
///
/// The 20-byte wire layout (`ScreenShareControlMessage.encodeReceiverReport`)
/// is untouched; only the reported values become truthful.
struct RRAccounting: Sendable {
    /// Sliding dedupe window, in packets, over the extended-seq space. Sized
    /// to comfortably cover the retransmit horizon: the server's ring keeps
    /// ~1 s of packets and the re-NACK tick is ~1 Hz, so a served retransmit
    /// can legitimately land thousands of packets behind `highestExt` at high
    /// bitrates (1024 was ≈ 310 ms at 32 Mbps — late fills fell off the
    /// window, were ignored, and biased fracLostQ8 UP, triggering needless
    /// bitrate cuts). 4096 packets ≈ 1.2 s at that rate; 64 UInt64 words.
    static let dedupeWindowBits = 4096
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
    var hasBaseline: Bool { highestExt >= 0 }

    /// Map a 16-bit sequence number into the extended space, choosing the
    /// cycle that lands nearest `near` (wrap-aware). Pure; may return a
    /// negative value for a straggler that precedes the session start.
    ///
    /// Limitation (accepted): a *forward* jump of more than 32768 packets is
    /// indistinguishable from a backward straggler in 16-bit space, so it
    /// extends backward and the arrival is ignored; the accounting self-heals
    /// on the next in-range packet. RFC 3550's MAX_DROPOUT pattern (treat a
    /// huge jump as a stream restart and re-baseline) is the future fix if
    /// real streams ever hit this — ours can't today (the server never skips
    /// that far within one session).
    static func extend(seq: UInt16, near: Int64) -> Int64 {
        let cycleBase = (near >> 16) << 16
        var best = cycleBase + Int64(seq)
        for alt in [best - 65536, best + 65536] where abs(alt - near) < abs(best - near) {
            best = alt
        }
        return best
    }

    /// Feed one received video packet's sequence number.
    mutating func observe(seq: UInt16) {
        guard highestExt >= 0 else {
            // First packet: it is both received and expected — the baseline
            // sits one before it so `expected = highest − baseline` counts it.
            highestExt = Int64(seq)
            baselineExt = highestExt - 1
            receivedInInterval = 1
            setSeen(highestExt)
            return
        }
        let ext = Self.extend(seq: seq, near: highestExt)
        if ext > highestExt {
            // New arrivals region: clear the window slots the jump exposes so
            // stale bits from a lap ago can't alias as "already seen".
            clearSeenRange(from: highestExt + 1, through: ext)
            highestExt = ext
        }
        // Only first arrivals within the dedupe window count. Stragglers
        // older than the window (or preceding the session) are ignored — the
        // window slot they'd map to now belongs to a newer seq.
        guard ext >= 0, ext > highestExt - Int64(Self.dedupeWindowBits) else { return }
        if !isSeen(ext) {
            setSeen(ext)
            receivedInInterval += 1
        }
    }

    /// Build the values for one receiver report and reset the interval
    /// accounting. Returns nil until the first packet arrives.
    mutating func makeReport() -> (fracLostQ8: UInt8, extHighestSeq: UInt32)? {
        guard highestExt >= 0 else { return nil }
        let expected = Int(highestExt - baselineExt)
        var fracQ8 = 0
        if expected > 0 {
            let lost = max(0, expected - receivedInInterval)
            fracQ8 = min(255, lost * 256 / expected)
        }
        // RFC 3550 form (cycles << 16 | highest) — the low 32 bits of the
        // monotone extended counter.
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
            // The jump wipes the whole window.
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
