import Foundation

// The deterministic input machinery the differential suites share. Fixed
// seeds, an explicit injected clock, and impairment applied ONCE to a plan
// that both implementations then consume — so a divergence is always a
// behavioral difference, never a difference in what the two sides were fed.

/// SplitMix64 — a tiny, well-distributed, endian-free PRNG. Chosen over
/// `SystemRandomNumberGenerator` because a differential failure must be
/// reproducible from the seed printed in the assertion message.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<bound` (bound > 0). Modulo bias is irrelevant here —
    /// the streams only need to be deterministic and varied, not uniform.
    mutating func next(upTo bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// True with roughly `percent` in 100 probability.
    mutating func chance(_ percent: Int) -> Bool {
        next(upTo: 100) < percent
    }
}

/// Reorders, drops and duplicates a delivery sequence — the same impairment
/// shape `LossyChannel` applies in the mac test suite, but over abstract
/// items so both packets and (seq, packet) pairs can ride it. Each surviving
/// item is displaced forward by up to `maxDisplacement` positions.
func impairDelivery<T>(
    _ items: [T], rng: inout SplitMix64,
    dropPercent: Int, duplicatePercent: Int, maxDisplacement: Int
) -> [T] {
    var scheduled: [(slot: Int, tiebreak: Int, item: T)] = []
    var tiebreak = 0
    for (index, item) in items.enumerated() {
        if rng.chance(dropPercent) { continue }
        scheduled.append((index + rng.next(upTo: maxDisplacement + 1), tiebreak, item))
        tiebreak += 1
        if rng.chance(duplicatePercent) {
            scheduled.append((index + rng.next(upTo: maxDisplacement + 1), tiebreak, item))
            tiebreak += 1
        }
    }
    scheduled.sort { ($0.slot, $0.tiebreak) < ($1.slot, $1.tiebreak) }
    return scheduled.map { $0.item }
}

/// A deterministic pseudo-random NAL unit: `header` is the codec's first
/// byte(s), the rest is seeded filler.
func makeNAL(header: [UInt8], size: Int, rng: inout SplitMix64) -> Data {
    var nal = Data(header)
    for _ in 0..<max(0, size - header.count) {
        nal.append(UInt8(truncatingIfNeeded: rng.next()))
    }
    return nal
}
