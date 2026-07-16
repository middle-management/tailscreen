import Foundation

/// Small per-packetizer pool of reusable `Data` buffers for RTP packet
/// construction. The brief: at 60 fps × N viewers the packetizer emits
/// thousands of short-lived `Data` allocations per second. This pool lets
/// each `packetize()` call recycle the previous call's storage in place
/// when the consumer is done with it, falling back to a fresh allocation
/// when it isn't.
///
/// ### Correctness argument (no aliasing)
///
/// `Data` is a value type with copy-on-write semantics: two `Data` values
/// can share a single underlying byte buffer, and any *mutation* of either
/// value first checks the buffer's refcount. If refcount > 1, the mutation
/// path allocates fresh storage for the mutating value, leaving the other
/// holder's bytes unchanged.
///
/// The pool exploits this. On each `packetize()`:
///
/// 1. The pool has an array of `Data` buffers from the *previous* call,
///    in `recycled`. The packetizer also still holds the previous
///    `packets` array, but it gave that array to the consumer (e.g. the
///    UDP broadcaster) and forgot it. So `recycled[i]` and the
///    consumer-held copies share underlying buffers via COW.
/// 2. `acquire(minCapacity:)` removes one entry from `recycled` (so the
///    pool side drops its reference) and calls
///    `removeAll(keepingCapacity: true)` on it.
///    - If the consumer has finished with their copy and dropped it
///      (the common case: the previous broadcast Task has completed),
///      refcount == 1 → the storage is reset in place, no allocation.
///    - If the consumer still holds their copy, refcount > 1 → `Data`
///      transparently allocates a fresh buffer for the pool side, and
///      the consumer's bytes remain intact. No aliasing.
/// 3. The packetizer fills the acquired buffer and appends it to a new
///    `packets` array, then calls `handOver(packets)` so the next call
///    can recycle this batch.
///
/// In the common "consumer is done" path, the pool reuses storage; in the
/// degenerate "consumer still holding" path, the pool degrades to fresh
/// allocations — which is exactly the no-pool behaviour we used to have.
/// It is impossible for two `Data` values returned by `acquire` (across
/// calls) to share a live buffer with anything else in a mutating way.
///
/// `@unchecked Sendable` because the pool's owning packetizer is itself
/// `@unchecked Sendable` (the screen-share server serializes calls
/// behind `broadcastTail`) and `Data`'s COW handles the cross-batch
/// alias safety.
public final class RTPPacketBufferPool: @unchecked Sendable {
    /// Buffers handed over from the previous `packetize` call. Each entry
    /// is a `Data` whose underlying storage is either uniquely held by
    /// the pool (consumer released) or shared (consumer still holding).
    /// Either way, the pool's mutating `removeAll(keepingCapacity:)` is
    /// safe.
    private var recycled: [Data] = []

    /// Default target capacity for a freshly-allocated buffer. Set just
    /// above one MTU's worth of RTP packet (RTP header 12 + payload 1100
    /// + a little FU header overhead).
    private let defaultCapacity: Int

    /// Soft cap: if a single `packetize` call would push the pool above
    /// this many slots (e.g. a huge keyframe split into thousands of
    /// fragments), older entries are dropped rather than retained
    /// forever. 512 covers the worst case we've observed (~3 MB keyframe
    /// at 1100-byte MTU ≈ 2730 packets, but we steady-state at hundreds).
    private let softLimit: Int

    public init(defaultCapacity: Int = 1200, softLimit: Int = 512) {
        self.defaultCapacity = defaultCapacity
        self.softLimit = softLimit
    }

    /// Number of buffers available to recycle (informational, used by the
    /// packetizer to hint `reserveCapacity`).
    public var recycledCount: Int { recycled.count }

    /// Acquire a buffer with `size == 0` and capacity sufficient for
    /// `minCapacity`. Reuses storage from the previous batch when the ask
    /// fits within `defaultCapacity` (the floor we pool-allocate at);
    /// otherwise allocates fresh and bypasses the pool. `Data` exposes no
    /// public `capacity` accessor, so we use `defaultCapacity` as the
    /// known-good lower bound for pooled buffers.
    public func acquire(minCapacity: Int) -> Data {
        // Oversized ask — pool buffers may not fit and `Data` won't tell
        // us their true capacity. Allocate fresh instead.
        if minCapacity > defaultCapacity {
            return Data(capacity: minCapacity)
        }
        if !recycled.isEmpty {
            // popLast (not removeFirst) — O(1), and we don't care about
            // emission order matching recycle order: each emitted packet
            // is independent of every other.
            var buf = recycled.removeLast()
            // After removeLast, the pool no longer references `buf`. If
            // the previous batch's consumer has also dropped their copy,
            // `buf` is now uniquely owned and removeAll reuses storage.
            // If not, COW kicks in and `buf` gets a fresh buffer — still
            // valid, just no reuse this round.
            buf.removeAll(keepingCapacity: true)
            return buf
        }
        return Data(capacity: defaultCapacity)
    }

    /// Stash the freshly-built batch so the *next* `packetize` call can
    /// recycle these buffers. The packetizer also returns this same array
    /// to the caller, so the buffers are simultaneously held by:
    ///   - the pool (here), refcount contribution = 1
    ///   - the caller's `templates: [Data]`, refcount contribution = 1
    ///
    /// On the next `packetize` call, `acquire` will pull from `recycled`;
    /// if the caller has by then released their array (Task completed),
    /// refcount drops to 1 and the reset is in-place.
    public func handOver(_ batch: [Data]) {
        // Drop any prior leftovers — those buffers' storage will be freed
        // (or kept alive by their consumer copies, who are responsible
        // for their own lifecycle now).
        recycled.removeAll(keepingCapacity: true)
        if batch.count <= softLimit {
            recycled.append(contentsOf: batch)
        } else {
            // Cap pool growth on pathological frames.
            recycled.append(contentsOf: batch.prefix(softLimit))
        }
    }
}
