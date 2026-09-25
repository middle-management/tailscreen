import XCTest

@testable import TailscreenProtocol

/// `CaptureTimings` / `CaptureTimingAccumulator` — the sharer-side answer to
/// "which part is slow". Must not lie: a still screen must not read as fast,
/// and the dominant stage must be named rather than left to be inferred.
final class CaptureTimingsTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let second: UInt64 = 1_000_000_000

    func testNoSnapshotBeforeAFullWindow() {
        var accumulator = CaptureTimingAccumulator()
        accumulator.record(
            nowNs: 0, acquireNs: ms, convertNs: ms, encodeNs: ms, producedFrame: true)
        XCTAssertNil(accumulator.snapshot(nowNs: second / 2))
    }

    func testAveragesAndFrameRateOverOneSecond() {
        var accumulator = CaptureTimingAccumulator()
        for index in 0..<10 {
            accumulator.record(
                nowNs: UInt64(index) * (second / 10),
                acquireNs: 2 * ms, convertNs: 40 * ms, encodeNs: 100 * ms,
                producedFrame: true)
        }
        guard let timings = accumulator.snapshot(nowNs: second) else {
            return XCTFail("a full window should produce a snapshot")
        }
        XCTAssertEqual(timings.frames, 10)
        XCTAssertEqual(timings.framesPerSecond, 10, accuracy: 0.01)
        XCTAssertEqual(timings.acquireMs, 2, accuracy: 0.01)
        XCTAssertEqual(timings.convertMs, 40, accuracy: 0.01)
        XCTAssertEqual(timings.encodeMs, 100, accuracy: 0.01)
        XCTAssertEqual(timings.slowestStage, "encode")
    }

    func testTimeoutsDoNotDragTheAveragesDown() {
        // A still screen: WGC yields nothing, most passes are timeouts. Averaging
        // their zero convert/encode times in would report idle as fast.
        var accumulator = CaptureTimingAccumulator()
        accumulator.record(
            nowNs: 0, acquireNs: 16 * ms, convertNs: 40 * ms, encodeNs: 100 * ms,
            producedFrame: true)
        for index in 1..<20 {
            accumulator.record(
                nowNs: UInt64(index) * (second / 20),
                acquireNs: 16 * ms, convertNs: 0, encodeNs: 0, producedFrame: false)
        }
        guard let timings = accumulator.snapshot(nowNs: second) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(timings.frames, 1)
        XCTAssertEqual(timings.timeouts, 19)
        XCTAssertEqual(timings.convertMs, 40, accuracy: 0.01, "averaged over frames, not passes")
        XCTAssertEqual(timings.encodeMs, 100, accuracy: 0.01)
        // Acquire IS averaged over every pass: a timeout really spent that time waiting.
        XCTAssertEqual(timings.acquireMs, 16, accuracy: 0.01)
    }

    func testTheWindowResetsAfterASnapshot() {
        var accumulator = CaptureTimingAccumulator()
        accumulator.record(
            nowNs: 0, acquireNs: 99 * ms, convertNs: 99 * ms, encodeNs: 99 * ms,
            producedFrame: true)
        XCTAssertNotNil(accumulator.snapshot(nowNs: second))

        accumulator.record(
            nowNs: second, acquireNs: ms, convertNs: 2 * ms, encodeNs: 3 * ms,
            producedFrame: true)
        guard let second = accumulator.snapshot(nowNs: 2 * self.second) else {
            return XCTFail("expected a second snapshot")
        }
        XCTAssertEqual(second.frames, 1)
        XCTAssertEqual(second.encodeMs, 3, accuracy: 0.01)
    }

    func testAnIdleWindowReportsZeroFramesWithoutDividingByZero() {
        var accumulator = CaptureTimingAccumulator()
        accumulator.record(
            nowNs: 0, acquireNs: 16 * ms, convertNs: 0, encodeNs: 0, producedFrame: false)
        guard let timings = accumulator.snapshot(nowNs: second) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(timings.frames, 0)
        XCTAssertEqual(timings.framesPerSecond, 0)
        XCTAssertEqual(timings.convertMs, 0)
        XCTAssertNil(timings.slowestStage, "nothing was encoded, so nothing was slowest")
        XCTAssertTrue(timings.summary.contains("idle"))
    }

    func testSlowestStageNamesTheOneToFix() {
        let conversionBound = CaptureTimings(
            framesPerSecond: 2, acquireMs: 1, convertMs: 300, encodeMs: 40,
            frames: 2, timeouts: 0)
        XCTAssertEqual(conversionBound.slowestStage, "convert")

        let captureBound = CaptureTimings(
            framesPerSecond: 2, acquireMs: 400, convertMs: 10, encodeMs: 20,
            frames: 2, timeouts: 0)
        XCTAssertEqual(captureBound.slowestStage, "capture")
    }

    func testSummaryCarriesTheNumbersAPersonNeeds() {
        let timings = CaptureTimings(
            framesPerSecond: 1.4, acquireMs: 3, convertMs: 41, encodeMs: 180,
            frames: 2, timeouts: 0)
        let summary = timings.summary
        XCTAssertTrue(summary.contains("1.4 fps"))
        XCTAssertTrue(summary.contains("convert 41 ms"))
        XCTAssertTrue(summary.contains("encode 180 ms"))
        XCTAssertFalse(summary.contains("idle"), "a busy screen reads cleanly")
    }

    func testSummaryNamesIdlePassesWhenThereAreAny() {
        // Stage timings alone can't distinguish 2fps with 38 idle passes from 2fps with none.
        let mostlyIdle = CaptureTimings(
            framesPerSecond: 2, acquireMs: 24, convertMs: 6, encodeMs: 3,
            frames: 2, timeouts: 38)
        XCTAssertTrue(mostlyIdle.summary.contains("38 idle"))
    }
}
