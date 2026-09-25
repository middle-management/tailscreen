import Foundation

/// Small per-packetizer pool of reusable `Data` buffers for RTP packet
/// construction. At 60fps × N viewers the packetizer emits thousands of
/// short-lived `Data` allocations per second; this pool recycles the
/// previous call's storage in place when the consumer is done with it,
/// falling back to a fresh allocation when it isn't.
///
/// ### Correctness (no aliasing)
///
/// `Data` is COW: mutating a value with refcount > 1 allocates fresh
/// storage rather than touching the other holder's bytes. Each `acquire`
/// pops one buffer from `recycled` (a previous batch, given to the
/// consumer and forgotten by the packetizer) and calls
/// `removeAll(keepingCapacity: true)` on it — in-place if the consumer
/// already dropped its copy (refcount == 1), otherwise COW silently
/// reallocates and the consumer's bytes stay intact. Degenerate case
/// (consumer still holding) just degrades to the no-pool behavior.
///
/// ### Thread safety
///
/// `recycled` lives behind a `Guarded` (see `Guarded.swift`), so `acquire`
/// pops under the lock — two concurrent calls can never receive the same
/// `Data` value. An earlier revision instead relied on the server
/// serializing all packetizer calls behind one send-chain Task, which no
/// longer holds now that sends are per-viewer; the lock makes the pool
/// correct on its own rather than borrowing that invariant. Interleaved
/// batches at worst forfeit reuse, never correctness.
public final class RTPPacketBufferPool: Sendable {
    /// Buffers handed over from the previous `packetize` call, behind the
    /// pool's lock. Popped entries get a safe mutating `removeAll` whether
    /// uniquely held by the pool or still shared with the consumer.
    private let recycled = Guarded<[Data]>([])

    /// Default target capacity for a freshly-allocated buffer: just above
    /// one MTU's worth of RTP packet (header 12 + payload 1100 + FU
    /// overhead).
    private let defaultCapacity: Int

    /// Soft cap on pool size (a huge keyframe can split into thousands of
    /// fragments); older entries are dropped past this rather than
    /// retained forever. 512 covers the observed worst case.
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
    /// fits within `defaultCapacity`; otherwise allocates fresh, since
    /// `Data` exposes no public `capacity` accessor to check pooled buffers
    /// against.
    public func acquire(minCapacity: Int) -> Data {
        // Oversized ask — pool buffers may not fit. Allocate fresh instead.
        if minCapacity > defaultCapacity {
            return Data(capacity: minCapacity)
        }
        // popLast: O(1); emission order needn't match recycle order.
        guard var buf = recycled.withLock({ $0.popLast() }) else {
            return Data(capacity: defaultCapacity)
        }
        // Outside the lock: COW reset needs no pool state, and reuses
        // storage if the consumer already dropped its copy.
        buf.removeAll(keepingCapacity: true)
        return buf
    }

    /// Stash the freshly-built batch so the *next* `packetize` call can
    /// recycle these buffers. The packetizer also hands this same array to
    /// the caller, so `acquire` on the next call sees refcount 1 (in-place
    /// reset) once the caller has released it.
    public func handOver(_ batch: [Data]) {
        recycled.withLock { recycled in
            // Drop prior leftovers; their storage is freed or kept alive by
            // whatever consumer copy still holds it.
            recycled.removeAll(keepingCapacity: true)
            if batch.count <= softLimit {
                recycled.append(contentsOf: batch)
            } else {
                recycled.append(contentsOf: batch.prefix(softLimit))  // cap growth
            }
        }
    }
}
