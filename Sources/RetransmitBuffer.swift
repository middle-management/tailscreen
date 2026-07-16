import Foundation
import Synchronization

/// Send-side ring of recently broadcast RTP packets, so the server can answer
/// a viewer NACK with a byte-identical retransmit at ~1 RTT for ~0.1 % of a
/// keyframe's cost (vs. the PLI path's full IDR).
///
/// Fan-out packets differ only in the header bytes `rewriteRTPHeader` rewrites
/// (sequence + SSRC); the payload is identical for every viewer. So the ring
/// stores each broadcast's **templates once** (seq=0 / ssrc=0, exactly what
/// `broadcast` packetizes), shared across viewers, plus a tiny per-viewer index
/// mapping that viewer's reserved sequence range back onto the shared batch. A
/// retransmit copies the template and re-runs `rewriteRTPHeader` with the
/// requested seq + the viewer's SSRC.
///
/// The ring owns its own `Data` copies (made after `broadcast` returns) rather
/// than retaining the packetizer's pooled buffers: retaining them would keep
/// their refcount > 1 and force `RTPPacketBufferPool` to COW instead of
/// recycle, defeating pooling on the hot path. The copies are cheap relative to
/// the UDP sends they enable a viewer to recover.
///
/// `@unchecked Sendable`: all state lives behind `lock`. The server records
/// from its broadcast site and looks up from the NACK-service path, both off
/// the cooperative pool — the lock owns the invariants the compiler can't see.
final class RetransmitBuffer: @unchecked Sendable {
    /// One recorded broadcast: the shared seq=0/ssrc=0 templates plus the
    /// metadata the triple-eviction policy reads.
    private struct Batch {
        let templates: [Data]
        let insertedNs: UInt64
        let byteCount: Int
    }

    /// Per-viewer reserved sequence range pointing back at a batch.
    private struct ViewerRange {
        let startSeq: UInt16
        let count: UInt16
        let batchID: UInt64
    }

    /// Evict a batch once it's older than this. 1 s ≈ one WAN RTT of slack
    /// beyond the retransmit deadline — a NACK for anything older has already
    /// fallen back to PLI on the viewer side.
    let windowNs: UInt64
    /// Evict oldest batches once the stored payload bytes exceed this. 4 MB ≈
    /// 1 s of a 32 Mbps 4K stream — bounds worst-case memory regardless of
    /// bitrate.
    let byteCap: Int
    /// Evict oldest batches once more than this many are held.
    let maxBatches: Int
    /// Keep at most this many recent sequence ranges per viewer (a viewer only
    /// ever NACKs recent history; older ranges point at evicted batches).
    let maxRangesPerViewer: Int

    // `Mutex` (not `OSAllocatedUnfairLock`) so this file stays portable —
    // it's part of the TailscreenProtocol Linux-buildable set.
    private let lock = Mutex<State>(State())
    private struct State {
        var batches: [UInt64: Batch] = [:]
        /// Batch IDs in insertion order, for oldest-first eviction.
        var order: [UInt64] = []
        var totalBytes: Int = 0
        var nextBatchID: UInt64 = 1
        var ranges: [String: [ViewerRange]] = [:]
    }

    init(
        windowNs: UInt64 = 1_000_000_000,
        byteCap: Int = 4 * 1024 * 1024,
        maxBatches: Int = 128,
        maxRangesPerViewer: Int = 128
    ) {
        self.windowNs = windowNs
        self.byteCap = byteCap
        self.maxBatches = maxBatches
        self.maxRangesPerViewer = maxRangesPerViewer
    }

    /// Record one broadcast's shared templates. Returns the assigned batch ID
    /// so the caller can register each viewer's reserved sequence range against
    /// it. `templates` is copied — see the type doc for why the ring must own
    /// its bytes. Applies the triple-eviction policy (age, bytes, count).
    @discardableResult
    func record(templates: [Data], nowNs: UInt64) -> UInt64 {
        let owned = templates.map { Data($0) }
        let bytes = owned.reduce(0) { $0 + $1.count }
        return lock.withLock { state in
            let id = state.nextBatchID
            state.nextBatchID &+= 1
            state.batches[id] = Batch(templates: owned, insertedNs: nowNs, byteCount: bytes)
            state.order.append(id)
            state.totalBytes += bytes
            Self.evict(&state, nowNs: nowNs, windowNs: windowNs, byteCap: byteCap, maxBatches: maxBatches)
            return id
        }
    }

    /// Register a viewer's reserved sequence range for a recorded batch, so a
    /// later NACK from that viewer resolves seq → batch template.
    func recordViewerRange(addr: String, startSeq: UInt16, count: UInt16, batchID: UInt64) {
        guard count >= 1 else { return }
        lock.withLock { state in
            var list = state.ranges[addr] ?? []
            list.append(ViewerRange(startSeq: startSeq, count: count, batchID: batchID))
            if list.count > maxRangesPerViewer {
                list.removeFirst(list.count - maxRangesPerViewer)
            }
            state.ranges[addr] = list
        }
    }

    /// True when `seq` (in `addr`'s sequence space) still resolves to a live
    /// batch template. The NACK budget consults this to convert
    /// no-longer-in-ring requests to PLI. Verifies the batch still exists AND
    /// the index is in bounds — mirroring `template()` exactly — because
    /// per-viewer ranges (evict at 128) outlive batches (evict by 1 s age /
    /// bytes / count), so a range can point at an already-evicted batch. Any
    /// disagreement with `template()` would let the budget serve a seq that
    /// then fails to send with no PLI fallback.
    func has(addr: String, seq: UInt16) -> Bool {
        lock.withLock { state in
            guard let (batchID, index) = Self.resolve(state, addr: addr, seq: seq) else { return false }
            guard let batch = state.batches[batchID], index < batch.templates.count else { return false }
            return true
        }
    }

    /// Resolve one requested sequence number to its shared template (seq=0 /
    /// ssrc=0). Caller rewrites the header with `seq` + the viewer's SSRC. nil
    /// when the batch has been evicted or the seq is outside every known range.
    func template(addr: String, seq: UInt16) -> Data? {
        lock.withLock { state in
            guard let (batchID, index) = Self.resolve(state, addr: addr, seq: seq) else { return nil }
            guard let batch = state.batches[batchID], index < batch.templates.count else { return nil }
            return batch.templates[index]
        }
    }

    /// Drop a viewer's ranges (viewer left / was expelled). Batches stay —
    /// they're shared and self-evict by age.
    func removeViewer(addr: String) {
        lock.withLock { state in _ = state.ranges.removeValue(forKey: addr) }
    }

    /// Reset everything (share stop).
    func reset() {
        lock.withLock { state in
            state.batches.removeAll()
            state.order.removeAll()
            state.ranges.removeAll()
            state.totalBytes = 0
        }
    }

    /// Wrap-safe resolution of a viewer seq to `(batchID, templateIndex)`.
    /// Scans newest-first so a wrapped-around seq matches the most recent range
    /// covering it. Static + `State`-only so it's trivially reasoned about.
    private static func resolve(_ state: State, addr: String, seq: UInt16) -> (UInt64, Int)? {
        guard let list = state.ranges[addr] else { return nil }
        for range in list.reversed() {
            let offset = seq &- range.startSeq
            if offset < range.count {
                return (range.batchID, Int(offset))
            }
        }
        return nil
    }

    /// Triple eviction: age first, then byte cap, then batch count — each
    /// removes oldest batches until it's satisfied. Static so it's unit
    /// testable via the public `record` path.
    private static func evict(
        _ state: inout State, nowNs: UInt64, windowNs: UInt64, byteCap: Int, maxBatches: Int
    ) {
        // Age first: drop the oldest batch while it's past the window.
        while let id = state.order.first, let peek = state.batches[id], nowNs &- peek.insertedNs > windowNs {
            state.order.removeFirst()
            if let batch = state.batches.removeValue(forKey: id) { state.totalBytes -= batch.byteCount }
        }
        // Byte cap.
        while state.totalBytes > byteCap, let id = state.order.first {
            state.order.removeFirst()
            if let batch = state.batches.removeValue(forKey: id) { state.totalBytes -= batch.byteCount }
        }
        // Batch count.
        while state.order.count > maxBatches, let id = state.order.first {
            state.order.removeFirst()
            if let batch = state.batches.removeValue(forKey: id) { state.totalBytes -= batch.byteCount }
        }
    }

    // MARK: - Retransmit budget (pure)

    /// Token-bucket state for the retransmit rate limiter. `tokens` is in
    /// packets; refilled at `BudgetConfig.tokensPerSecond`.
    struct BudgetState: Equatable {
        var tokens: Double
        var lastRefillNs: UInt64
    }

    /// Retransmit rate-limit configuration. `tokensPerSecond` is derived from
    /// 25 % of the current bitrate divided by a nominal packet size; `maxTokens`
    /// caps burst.
    struct BudgetConfig: Equatable {
        var tokensPerSecond: Double
        var maxTokens: Double
    }

    /// Pure retransmit-budget decision: refill the token bucket, then walk the
    /// requested sequence numbers. A seq still in the ring and within budget is
    /// **served** (one token spent); a seq no longer in the ring, or one that
    /// runs the bucket dry, converts to the PLI fallback so recovery is never
    /// worse than today's keyframe path. Extracted per the extract-the-decision
    /// rule so the budget math is unit testable without a live socket.
    static func retransmitDecision(
        requested: [UInt16],
        ringHas: (UInt16) -> Bool,
        state: inout BudgetState,
        config: BudgetConfig,
        nowNs: UInt64
    ) -> (serve: [UInt16], fallbackPLI: Bool) {
        let elapsedNs = nowNs &- state.lastRefillNs
        let refill = Double(elapsedNs) / 1_000_000_000.0 * config.tokensPerSecond
        state.tokens = min(config.maxTokens, state.tokens + refill)
        state.lastRefillNs = nowNs

        var serve: [UInt16] = []
        var fallbackPLI = false
        for seq in requested {
            guard ringHas(seq) else {
                fallbackPLI = true
                continue
            }
            if state.tokens >= 1 {
                state.tokens -= 1
                serve.append(seq)
            } else {
                fallbackPLI = true
            }
        }
        return (serve, fallbackPLI)
    }
}
