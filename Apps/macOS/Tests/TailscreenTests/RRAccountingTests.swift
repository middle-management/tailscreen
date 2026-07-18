import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Pure-decision tests for `RRAccounting` — the viewer's receiver-report
/// bookkeeping, extracted from `TailscaleScreenShareClient` so the baseline
/// and duplicate fixes are pinned on CI. See the type's doc comment for the
/// two defects the extraction fixed.
final class RRAccountingTests: XCTestCase {
    func testNoReportBeforeFirstPacket() {
        var acc = RRAccounting()
        XCTAssertFalse(acc.hasBaseline)
        XCTAssertNil(acc.makeReport())
    }

    func testBaselineIntervalCountsFirstPacketInBothLegs() throws {
        // The historical defect: N in-order packets yielded expected = N−1,
        // received = N, so one real loss in the first interval was masked.
        var acc = RRAccounting()
        for seq in 0..<10 {
            acc.observe(seq: UInt16(seq))
        }
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(report.fracLostQ8, 0, "10 packets, no loss → zero fraction lost")
        XCTAssertEqual(report.extHighestSeq, 9)
    }

    func testSingleLossInFirstIntervalIsReported() throws {
        var acc = RRAccounting()
        for seq in [0, 1, 2, 3, 4, 6, 7, 8, 9] {  // 5 lost
            acc.observe(seq: UInt16(seq))
        }
        let report = try XCTUnwrap(acc.makeReport())
        // expected = 10, received = 9 → 1 × 256 / 10 = 25 (Q8 ≈ 10 %).
        XCTAssertEqual(report.fracLostQ8, 25, "one loss out of ten must not be masked")
    }

    func testDuplicatesDoNotInflateReceived() throws {
        var acc = RRAccounting()
        for seq in [0, 1, 2, 3, 4, 6, 7, 8, 9] {
            acc.observe(seq: UInt16(seq))
            acc.observe(seq: UInt16(seq))  // every packet duplicated
        }
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(
            report.fracLostQ8, 25,
            "duplicates must not be counted as received — they'd mask the real loss")
    }

    func testServedRetransmitCountsOnceAsReceived() throws {
        var acc = RRAccounting()
        acc.observe(seq: 0)
        acc.observe(seq: 1)
        acc.observe(seq: 3)  // 2 missing
        acc.observe(seq: 4)
        acc.observe(seq: 2)  // NACK retransmit lands: first arrival, counts
        acc.observe(seq: 2)  // …but the duplicate of it doesn't
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(report.fracLostQ8, 0, "a served retransmit is recovered loss, not loss")
        XCTAssertEqual(report.extHighestSeq, 4)
    }

    func testWrapAcross65535ExtendsSequenceSpace() throws {
        var acc = RRAccounting()
        for seq in [65530, 65531, 65532, 65533, 65534, 65535] {
            acc.observe(seq: UInt16(seq))
        }
        for seq in 0...4 {
            acc.observe(seq: UInt16(seq))
        }
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(report.fracLostQ8, 0, "a clean wrap is not loss")
        XCTAssertEqual(
            report.extHighestSeq, (1 << 16) | 4,
            "extended highest must carry the cycle count (RFC 3550 form)")
    }

    func testLossAcrossTheWrapIsReported() throws {
        var acc = RRAccounting()
        acc.observe(seq: 65534)
        acc.observe(seq: 65535)
        // 0 and 1 lost across the boundary.
        acc.observe(seq: 2)
        acc.observe(seq: 3)
        let report = try XCTUnwrap(acc.makeReport())
        // expected = 6, received = 4 → 2 × 256 / 6 = 85.
        XCTAssertEqual(report.fracLostQ8, 85)
    }

    func testFirstSeqZeroDoesNotUnderflow() throws {
        // The old code stored the baseline as UInt32(firstSeq); the fixed
        // form stores extFirst − 1, which for seq 0 must go to −1, not wrap.
        var acc = RRAccounting()
        acc.observe(seq: 0)
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(report.fracLostQ8, 0)
        XCTAssertEqual(report.extHighestSeq, 0)
    }

    func testSecondIntervalStartsFromNewBaseline() throws {
        var acc = RRAccounting()
        for seq in 0..<10 {
            acc.observe(seq: UInt16(seq))
        }
        _ = acc.makeReport()
        // Second interval: 4 of 5 arrive.
        for seq in [10, 11, 13, 14] {
            acc.observe(seq: UInt16(seq))
        }
        let report = try XCTUnwrap(acc.makeReport())
        // expected = 5 (10…14), received = 4 → 1 × 256 / 5 = 51.
        XCTAssertEqual(report.fracLostQ8, 51)
        XCTAssertEqual(report.extHighestSeq, 14)
    }

    func testStragglerOlderThanWindowIsIgnored() throws {
        var acc = RRAccounting()
        acc.observe(seq: 5000)
        // 500 is outside the 4096-packet dedupe window behind 5000; its
        // window slot belongs to a newer seq, so it must not count.
        acc.observe(seq: 500)
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(report.extHighestSeq, 5000)
        XCTAssertEqual(report.fracLostQ8, 0, "expected = received = 1 (baseline only)")
    }

    func testPreSessionStragglerIsIgnored() throws {
        var acc = RRAccounting()
        acc.observe(seq: 5)  // ext 5
        acc.observe(seq: 65533)  // extends to −3: precedes the session
        let report = try XCTUnwrap(acc.makeReport())
        XCTAssertEqual(report.extHighestSeq, 5)
        XCTAssertEqual(report.fracLostQ8, 0)
    }

    func testExtendPicksNearestCycle() {
        XCTAssertEqual(RRAccounting.extend(seq: 2, near: 65535), 65538)
        XCTAssertEqual(RRAccounting.extend(seq: 65533, near: 65538), 65533)
        XCTAssertEqual(RRAccounting.extend(seq: 100, near: 100), 100)
        XCTAssertEqual(RRAccounting.extend(seq: 65533, near: 5), -3)
    }

    func testWindowLapClearsStaleSeenBits() throws {
        // A seq whose window slot was used a lap ago must still count as a
        // first arrival after the window advances past the old occupant.
        var acc = RRAccounting()
        acc.observe(seq: 0)
        _ = acc.makeReport()
        // Jump forward exactly one window: seq 4096 maps to slot 0 (same as
        // seq 0). Without the range-clear it would read as "already seen".
        acc.observe(seq: UInt16(RRAccounting.dedupeWindowBits))
        let report = try XCTUnwrap(acc.makeReport())
        // expected = 4096 (1…4096), received = 1 → heavy loss, but the key
        // point is the arrival was COUNTED (received = 1, not 0):
        // lost = 4095 → 4095 × 256 / 4096 = 255.
        XCTAssertEqual(report.fracLostQ8, 255)
        XCTAssertEqual(report.extHighestSeq, UInt32(RRAccounting.dedupeWindowBits))
    }

    func testLateFillBeyondOldWindowStillCounts() throws {
        // The dedupe window must cover the server's retransmit horizon: a
        // served NACK fill can land far behind `highest` at high bitrates.
        // Here 20 packets go missing, the stream runs ~1900 packets past
        // them, and the retransmits then arrive >1024 behind highest — under
        // the old 1024-packet window they were ignored (counted as lost);
        // under the 4096 window they count and the interval reports clean.
        var acc = RRAccounting()
        for seq in 0..<100 {
            acc.observe(seq: UInt16(seq))
        }
        for seq in 120..<2048 {  // 100…119 lost in transit
            acc.observe(seq: UInt16(seq))
        }
        for seq in 100..<120 {  // …and served by retransmission, late
            acc.observe(seq: UInt16(seq))
        }
        let report = try XCTUnwrap(acc.makeReport())
        // expected = 2048, received = 2048 → no loss. With the fills dropped
        // (old window) this reported 20 lost → fracLostQ8 = 2, not 0.
        XCTAssertEqual(report.fracLostQ8, 0, "late fills within the window must count as received")
        XCTAssertEqual(report.extHighestSeq, 2047)
    }
}
