import Foundation

/// Deterministic, seedable RNG (SplitMix64). `SystemRandomNumberGenerator`
/// can't be seeded, and impairment tests must be reproducible run-to-run so a
/// failure points at a real regression, not a flaky draw.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the all-zero fixed point that would make `next()` constant.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Deterministic packet-impairment transform that models the WAN / DERP
/// failure modes loopback and local-headscale never produce — packet **loss**,
/// **reordering**, and **duplication**.
///
/// Feed it packets in send order; it returns them in the (mis)order a receiver
/// would observe, with some dropped and some duplicated. Because it's pure and
/// reproducible (seeded PRNG; no root, no network, no tsnet) it runs in CI —
/// unlike `scripts/net-impair.sh`, which impairs the live tsnet transport and
/// is therefore local-only. This is the CI-able way to exercise the
/// depacketizer's reorder/loss-recovery paths end-to-end with the real
/// packetizer.
struct LossyChannel {
    /// Probability in `0...1` that a given packet is dropped.
    var lossRate: Double
    /// Probability in `0...1` that a given surviving packet is duplicated.
    var dupRate: Double
    /// Packets are shuffled within consecutive windows of this many packets, so
    /// any packet is displaced by at most `reorderWindow - 1` positions. `0` or
    /// `1` means in-order. Keep it ≤ the depacketizer's reorder depth to model
    /// *recoverable* reordering (beyond that the depacketizer rightly treats
    /// the gap as loss).
    var reorderWindow: Int

    private var rng: SeededRNG

    init(seed: UInt64, lossRate: Double = 0, dupRate: Double = 0, reorderWindow: Int = 0) {
        self.lossRate = lossRate
        self.dupRate = dupRate
        self.reorderWindow = reorderWindow
        self.rng = SeededRNG(seed: seed)
    }

    /// Run `packets` (in send order) through the channel; returns the received
    /// order after loss, duplication, and bounded reordering are applied.
    mutating func transmit(_ packets: [Data]) -> [Data] {
        // 1. Loss + duplication, order preserved.
        var staged: [Data] = []
        staged.reserveCapacity(packets.count)
        for p in packets {
            if lossRate > 0, Double.random(in: 0..<1, using: &rng) < lossRate {
                continue  // dropped in transit
            }
            staged.append(p)
            if dupRate > 0, Double.random(in: 0..<1, using: &rng) < dupRate {
                staged.append(p)  // duplicated in transit
            }
        }

        // 2. Bounded reordering: shuffle within consecutive windows so a packet
        // is never displaced further than `reorderWindow - 1` slots.
        guard reorderWindow > 1 else { return staged }
        var out: [Data] = []
        out.reserveCapacity(staged.count)
        var i = 0
        while i < staged.count {
            let end = min(i + reorderWindow, staged.count)
            var chunk = Array(staged[i..<end])
            chunk.shuffle(using: &rng)
            out.append(contentsOf: chunk)
            i = end
        }
        return out
    }
}
