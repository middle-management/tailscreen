import Dispatch
import Foundation
import XCTest

@testable import TailscreenProtocol

/// Pure-logic tests for the send-side `RetransmitBuffer`: seq → template
/// lookup (including UInt16 wraparound), the triple eviction policy (age /
/// bytes / batch count), and the token-bucket retransmit budget that converts
/// over-budget or evicted requests to the PLI fallback.
final class RetransmitBufferTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    private func templates(_ ids: [UInt8]) -> [Data] {
        ids.map { Data([$0, 0, 0, 0]) }
    }

    func testLookupResolvesViewerSeqToTemplate() {
        let buf = RetransmitBuffer()
        let batch = buf.record(templates: templates([10, 11, 12]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 100, count: 3, batchID: batch)

        XCTAssertEqual(buf.template(addr: "v1", seq: 100), Data([10, 0, 0, 0]))
        XCTAssertEqual(buf.template(addr: "v1", seq: 101), Data([11, 0, 0, 0]))
        XCTAssertEqual(buf.template(addr: "v1", seq: 102), Data([12, 0, 0, 0]))
        XCTAssertTrue(buf.has(addr: "v1", seq: 101))
        // Outside the range → no template.
        XCTAssertNil(buf.template(addr: "v1", seq: 103))
        XCTAssertFalse(buf.has(addr: "v1", seq: 103))
        // Unknown viewer → no template.
        XCTAssertNil(buf.template(addr: "v2", seq: 100))
    }

    func testSeqWraparoundLookup() {
        let buf = RetransmitBuffer()
        let batch = buf.record(templates: templates([1, 2, 3]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 0xFFFF, count: 3, batchID: batch)
        XCTAssertEqual(buf.template(addr: "v1", seq: 0xFFFF), Data([1, 0, 0, 0]))
        XCTAssertEqual(buf.template(addr: "v1", seq: 0x0000), Data([2, 0, 0, 0]))
        XCTAssertEqual(buf.template(addr: "v1", seq: 0x0001), Data([3, 0, 0, 0]))
    }

    func testEvictionByBatchCount() {
        let buf = RetransmitBuffer(windowNs: .max, byteCap: .max, maxBatches: 2)
        let b0 = buf.record(templates: templates([0]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 0, count: 1, batchID: b0)
        let b1 = buf.record(templates: templates([1]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 1, count: 1, batchID: b1)
        let b2 = buf.record(templates: templates([2]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 2, count: 1, batchID: b2)
        // b0 evicted (oldest, over the 2-batch cap); its seq now misses.
        XCTAssertNil(buf.template(addr: "v1", seq: 0))
        XCTAssertNotNil(buf.template(addr: "v1", seq: 1))
        XCTAssertNotNil(buf.template(addr: "v1", seq: 2))
    }

    func testEvictionByAge() {
        let buf = RetransmitBuffer(windowNs: s, byteCap: .max, maxBatches: .max)
        let b0 = buf.record(templates: templates([0]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 0, count: 1, batchID: b0)
        // A record 2 s later evicts the now-stale first batch (1 s window).
        let b1 = buf.record(templates: templates([1]), nowNs: 2 * s)
        buf.recordViewerRange(addr: "v1", startSeq: 1, count: 1, batchID: b1)
        XCTAssertNil(buf.template(addr: "v1", seq: 0))
        XCTAssertNotNil(buf.template(addr: "v1", seq: 1))
    }

    func testEvictionByBytes() {
        // Each template is 4 bytes; cap at 6 bytes holds only one batch.
        let buf = RetransmitBuffer(windowNs: .max, byteCap: 6, maxBatches: .max)
        let b0 = buf.record(templates: templates([0]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 0, count: 1, batchID: b0)
        let b1 = buf.record(templates: templates([1]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 1, count: 1, batchID: b1)
        XCTAssertNil(buf.template(addr: "v1", seq: 0))
        XCTAssertNotNil(buf.template(addr: "v1", seq: 1))
    }

    func testHasAgreesWithTemplateAfterEviction() {
        // Regression: `has()` must verify the batch still exists AND the index
        // is in bounds, exactly like `template()`. Per-viewer ranges outlive
        // batches, so a range can point at an evicted batch — if `has()` said
        // "yes" there, the budget would serve a seq that then fails to send
        // with no PLI fallback.
        let buf = RetransmitBuffer(windowNs: .max, byteCap: .max, maxBatches: 1)
        let b0 = buf.record(templates: templates([0]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 0, count: 1, batchID: b0)
        XCTAssertTrue(buf.has(addr: "v1", seq: 0))
        XCTAssertNotNil(buf.template(addr: "v1", seq: 0))
        // Second batch evicts b0 (maxBatches 1); v1's range for b0 lingers.
        let b1 = buf.record(templates: templates([1]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 1, count: 1, batchID: b1)
        XCTAssertNil(buf.template(addr: "v1", seq: 0))
        XCTAssertFalse(buf.has(addr: "v1", seq: 0), "has() must not claim an evicted batch is live")
        XCTAssertTrue(buf.has(addr: "v1", seq: 1))
        XCTAssertNotNil(buf.template(addr: "v1", seq: 1))
    }

    func testRemoveViewerDropsRanges() {
        let buf = RetransmitBuffer()
        let b0 = buf.record(templates: templates([0]), nowNs: 0)
        buf.recordViewerRange(addr: "v1", startSeq: 0, count: 1, batchID: b0)
        buf.removeViewer(addr: "v1")
        XCTAssertNil(buf.template(addr: "v1", seq: 0))
    }

    // MARK: - Budget

    func testBudgetServesWithinTokensAndFallsBackWhenDry() {
        var state = RetransmitBuffer.BudgetState(tokens: 2, lastRefillNs: 0)
        let config = RetransmitBuffer.BudgetConfig(tokensPerSecond: 0, maxTokens: 10)
        // Three requested, all in the ring, but only 2 tokens → third → PLI.
        let decision = RetransmitBuffer.retransmitDecision(
            requested: [1, 2, 3], ringHas: { _ in true }, state: &state, config: config, nowNs: 0)
        XCTAssertEqual(decision.serve, [1, 2])
        XCTAssertTrue(decision.fallbackPLI)
        XCTAssertEqual(state.tokens, 0)
    }

    func testBudgetConvertsEvictedSeqToPLI() {
        var state = RetransmitBuffer.BudgetState(tokens: 10, lastRefillNs: 0)
        let config = RetransmitBuffer.BudgetConfig(tokensPerSecond: 0, maxTokens: 10)
        // seq 2 no longer in the ring → PLI; the others still served.
        let decision = RetransmitBuffer.retransmitDecision(
            requested: [1, 2, 3], ringHas: { $0 != 2 }, state: &state, config: config, nowNs: 0)
        XCTAssertEqual(decision.serve, [1, 3])
        XCTAssertTrue(decision.fallbackPLI)
    }

    func testBudgetRefillsOverTime() {
        var state = RetransmitBuffer.BudgetState(tokens: 0, lastRefillNs: 0)
        let config = RetransmitBuffer.BudgetConfig(tokensPerSecond: 100, maxTokens: 100)
        // 1 s later, 100 tokens refilled — one request served, no fallback.
        let decision = RetransmitBuffer.retransmitDecision(
            requested: [7], ringHas: { _ in true }, state: &state, config: config, nowNs: s)
        XCTAssertEqual(decision.serve, [7])
        XCTAssertFalse(decision.fallbackPLI)
        XCTAssertEqual(state.tokens, 99)
    }

    func testBudgetCapsAtMaxTokens() {
        var state = RetransmitBuffer.BudgetState(tokens: 0, lastRefillNs: 0)
        let config = RetransmitBuffer.BudgetConfig(tokensPerSecond: 1000, maxTokens: 5)
        _ = RetransmitBuffer.retransmitDecision(
            requested: [], ringHas: { _ in true }, state: &state, config: config, nowNs: s)
        XCTAssertEqual(state.tokens, 5)  // clamped despite 1000 accrued
    }

    // MARK: - Concurrency

    /// Record from several threads while others look up, which is how the
    /// server actually uses this: `record` / `recordViewerRange` run on the
    /// broadcast site and `template` / `has` on the NACK-service path, both
    /// off the cooperative pool.
    ///
    /// Like the buffer-pool case, this exists so the `linux-tsan` job has a
    /// concurrent execution to observe — the type's `@unchecked Sendable`
    /// rests entirely on its lock, and a lock nothing exercises concurrently
    /// is a claim the sanitiser never gets to check. (And it is on `Guarded`
    /// rather than `Synchronization.Mutex` so that the sanitiser can see the
    /// lock at all; see `Guarded.swift`.)
    ///
    /// The load-bearing assertion is **wholeness**: every template that comes
    /// back must be one of the exact 4-byte values that were recorded. A
    /// retransmit is supposed to be byte-identical to the original, so a torn
    /// or partially-published entry here would put malformed RTP on the wire
    /// — a failure that is invisible on the sharer and looks like link
    /// corruption to the viewer.
    func testConcurrentRecordAndLookupNeverYieldsATornTemplate() {
        let buf = RetransmitBuffer(
            windowNs: 10 * s,
            byteCap: 1 << 20,
            maxBatches: 32,
            maxRangesPerViewer: 32
        )
        let torn = Guarded(0)
        let resolved = Guarded(0)

        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            let addr = "v\(thread)"
            for round in 0..<200 {
                // Inlined rather than calling the `templates` helper: this
                // closure is `@Sendable`, and an XCTestCase is not.
                let batch = buf.record(
                    templates: (0..<4).map { Data([UInt8((thread &* 4 &+ $0) % 256), 0, 0, 0]) },
                    nowNs: UInt64(round) * 1_000_000
                )
                buf.recordViewerRange(
                    addr: addr,
                    startSeq: UInt16(truncatingIfNeeded: round &* 4),
                    count: 4,
                    batchID: batch
                )

                // Read back our own range, and one belonging to a neighbour —
                // so lookups genuinely cross threads rather than each thread
                // only ever reading what it just wrote.
                for peer in [addr, "v\((thread &+ 1) % 8)"] {
                    for offset in 0..<4 {
                        let seq = UInt16(truncatingIfNeeded: round &* 4 &+ offset)
                        guard let template = buf.template(addr: peer, seq: seq) else { continue }
                        resolved.withLock { $0 += 1 }
                        // Every recorded template is exactly `[id, 0, 0, 0]`.
                        if template.count != 4 || template.dropFirst() != Data([0, 0, 0]) {
                            torn.withLock { $0 += 1 }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(
            torn.withLock { $0 }, 0,
            "a retransmit template must come back whole, never partially published"
        )
        XCTAssertGreaterThan(
            resolved.withLock { $0 }, 0,
            "the run must actually resolve templates, or it proves nothing"
        )
    }
}
