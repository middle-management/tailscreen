import Foundation
import Synchronization

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
/// ### Thread safety
///
/// `recycled` lives behind a `Mutex` (the same `Synchronization` primitive
/// `RetransmitBuffer` uses), so `acquire` / `handOver` / `recycledCount`
/// are safe from any thread: each `acquire` pops its entry under the lock,
/// so two concurrent calls can never receive the same `Data` value, and
/// `Data`'s COW handles the cross-batch alias safety exactly as above.
/// (An earlier revision instead relied on the screen-share server
/// serializing all packetizer calls behind a single send-chain Task —
/// `broadcastTail` — but that chain was replaced by per-*viewer* send
/// chains, which serialize sends, not calls into the shared packetizers.
/// The lock makes the pool correct on its own terms instead of borrowing
/// an invariant from a caller that no longer holds it.) Interleaved
/// concurrent batches at worst forfeit reuse — one `handOver` dropping
/// another's leftovers just falls back to fresh allocation — never
/// correctness.
public final class RTPPacketBufferPool: Sendable {
    /// Buffers handed over from the previous `packetize` call, behind the
    /// pool's lock. Each entry is a `Data` whose underlying storage is
    /// either uniquely held by the pool (consumer released) or shared
    /// (consumer still holding). Either way, the mutating
    /// `removeAll(keepingCapacity:)` a popped entry receives is safe.
    private let recycled = Mutex<[Data]>([])

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
    public var recycledCount: Int { recycled.withLock { $0.count } }

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
        // popLast (not removeFirst) — O(1), and we don't care about
        // emission order matching recycle order: each emitted packet
        // is independent of every other.
        guard var buf = recycled.withLock({ $0.popLast() }) else {
            return Data(capacity: defaultCapacity)
        }
        // After the locked pop, the pool no longer references `buf` and no
        // other `acquire` can have received the same entry. If the previous
        // batch's consumer has also dropped their copy, `buf` is now
        // uniquely owned and removeAll reuses storage. If not, COW kicks in
        // and `buf` gets a fresh buffer — still valid, just no reuse this
        // round. Deliberately outside the lock: the COW check/copy needs no
        // pool state.
        buf.removeAll(keepingCapacity: true)
        return buf
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
        recycled.withLock { recycled in
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
}
