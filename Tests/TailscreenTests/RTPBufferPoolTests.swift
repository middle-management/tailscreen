import XCTest

@testable import Tailscreen

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
}
