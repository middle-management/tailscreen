import Foundation
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

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
}
