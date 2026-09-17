import Dispatch
import Foundation
import XCTest

@testable import TailscreenProtocol

/// Direct unit tests for `RTPPacketBufferPool`. The packetizer-level
/// aliasing tests in `RTPPacketTests` cover the pool indirectly through
/// real packetize calls; these pin down the pool's own contract — empty
/// acquire, recycle accounting, the soft cap on pathological frames, the
/// oversized-ask bypass, and COW safety for a consumer that still holds
/// the previous batch.
final class RTPBufferPoolTests: XCTestCase {

    func testAcquireFromEmptyPoolReturnsEmptyBuffer() {
        let pool = RTPPacketBufferPool()
        let buf = pool.acquire(minCapacity: 100)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(pool.recycledCount, 0)
    }

    func testHandOverMakesBuffersRecyclable() {
        let pool = RTPPacketBufferPool()
        pool.handOver([Data([1, 2, 3]), Data([4, 5])])
        XCTAssertEqual(pool.recycledCount, 2)

        // Acquired buffers come back reset to zero length regardless of
        // what the previous batch left in them.
        let buf = pool.acquire(minCapacity: 3)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(pool.recycledCount, 1)
    }

    func testHandOverReplacesPriorLeftovers() {
        let pool = RTPPacketBufferPool()
        pool.handOver([Data([1]), Data([2]), Data([3])])
        pool.handOver([Data([4])])
        // Not additive: leftovers from the previous batch are dropped.
        XCTAssertEqual(pool.recycledCount, 1)
    }

    func testSoftLimitCapsPoolGrowth() {
        let pool = RTPPacketBufferPool(defaultCapacity: 16, softLimit: 4)
        pool.handOver((0..<10).map { Data([UInt8($0)]) })
        XCTAssertEqual(pool.recycledCount, 4)
    }

    func testOversizedAskBypassesThePool() {
        let pool = RTPPacketBufferPool(defaultCapacity: 16, softLimit: 4)
        pool.handOver([Data([1, 2, 3])])

        // minCapacity above defaultCapacity can't trust a pooled buffer's
        // (unknowable) capacity — it must allocate fresh and leave the
        // pool untouched.
        let buf = pool.acquire(minCapacity: 1000)
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(pool.recycledCount, 1)
    }

    func testRecycledBufferMutationNeverCorruptsConsumerCopy() {
        let pool = RTPPacketBufferPool(defaultCapacity: 16, softLimit: 4)

        // Batch 1: consumer receives the packets AND the pool retains them
        // for recycling — exactly what handOver sets up.
        var first = pool.acquire(minCapacity: 8)
        first.append(contentsOf: [0xAA, 0xBB, 0xCC])
        let consumerCopy = first
        pool.handOver([first])

        // Batch 2: the consumer still holds its copy, so the reset-in-place
        // must degrade to a fresh allocation (Data's COW) rather than
        // scribbling over the consumer's bytes.
        var second = pool.acquire(minCapacity: 8)
        second.append(contentsOf: [0x11, 0x22, 0x33])

        XCTAssertEqual(consumerCopy, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(second, Data([0x11, 0x22, 0x33]))
    }

    // MARK: - Concurrency

    /// Hammer the pool from several threads at once.
    ///
    /// This suite's other cases are single-threaded, and the pool's own doc
    /// comment argues at length that `acquire` / `handOver` / `recycledCount`
    /// are safe from any thread — an argument nothing was checking. It exists
    /// primarily to give the `linux-tsan` job something to *observe* on the
    /// type: the sanitiser only reports a race it actually sees executed, so a
    /// lock-guarded type with no concurrent test is invisible to the gate even
    /// though the gate is green.
    ///
    /// That is also why the pool is on `Guarded` rather than
    /// `Synchronization.Mutex` — under `Mutex` this test would report a
    /// "Swift access race" inside the lock body on correct code. See
    /// `Guarded.swift`.
    ///
    /// The assertions are the interleaving-independent ones: an acquired
    /// buffer is always empty (a torn hand-off would show up as a non-zero
    /// count, since every recycled buffer was written to before hand-over),
    /// and the pool stays under its soft cap no matter how the batches
    /// interleave.
    func testConcurrentAcquireAndHandOverHoldsTheContract() {
        let softLimit = 64
        let pool = RTPPacketBufferPool(defaultCapacity: 1200, softLimit: softLimit)
        let nonEmptyAcquires = Guarded(0)

        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for round in 0..<200 {
                var batch: [Data] = []
                for index in 0..<8 {
                    var buf = pool.acquire(minCapacity: 64)
                    if !buf.isEmpty {
                        nonEmptyAcquires.withLock { $0 += 1 }
                    }
                    buf.append(contentsOf: [UInt8(thread), UInt8(round % 256), UInt8(index)])
                    batch.append(buf)
                }
                pool.handOver(batch)
                _ = pool.recycledCount
            }
        }

        XCTAssertEqual(
            nonEmptyAcquires.withLock { $0 }, 0,
            "acquire must always hand back a reset buffer, however batches interleave"
        )
        XCTAssertLessThanOrEqual(
            pool.recycledCount, softLimit,
            "the soft cap must hold under concurrent hand-overs"
        )
    }
}
