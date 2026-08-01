import XCTest

@testable import TailscreenProtocol

/// Tests for `CaptureTimings` / `CaptureTimingAccumulator` — the sharer-side
/// answer to "which part is slow".
///
/// The two behaviours worth pinning are both about not lying. A still screen
/// must not read as a fast sharer, and a sharer whose encode dominates must
/// say `encode` rather than leaving someone to infer it from a frame rate.
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
        // A still screen: WGC yields nothing, so most passes are timeouts.
        // Averaging their zero convert/encode times in would report a sharer
        // that is fast when it is simply idle — and that is exactly the
        // question this type exists to answer.
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
        // Acquire IS averaged over every pass: a timeout really did spend that
        // time waiting.
        XCTAssertEqual(timings.acquireMs, 16, accuracy: 0.01)
    }

    func testTheWindowResetsAfterASnapshot() {
        var accumulator = CaptureTimingAccumulator()
        accumulator.record(
            nowNs: 0, acquireNs: 99 * ms, convertNs: 99 * ms, encodeNs: 99 * ms,
            producedFrame: true)
        XCTAssertNotNil(accumulator.snapshot(nowNs: second))

        // A second window must not inherit the first one's totals.
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
        // Two frames a second with 38 idle passes and two frames a second with
        // none are completely different problems, and the stage timings alone
        // cannot tell them apart.
        let mostlyIdle = CaptureTimings(
            framesPerSecond: 2, acquireMs: 24, convertMs: 6, encodeMs: 3,
            frames: 2, timeouts: 38)
        XCTAssertTrue(mostlyIdle.summary.contains("38 idle"))
    }
}
