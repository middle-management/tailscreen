import XCTest

@testable import TailscreenViewer

/// The viewer HUD's frames-per-second window.
///
/// Worth testing rather than eyeballing because every failure mode here is a
/// plausible-looking number: a first reading of several billion, a reading
/// that halves because the window anchor drifted, or a session boundary that
/// reports a fraction of an fps. None of them look like a crash.
final class FrameRateCounterTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testFirstFrameOpensTheWindowWithoutReporting() {
        var counter = FrameRateCounter()
        // Reporting here would divide by an epoch of zero and produce a
        // several-billion-fps reading on the very first frame of every session.
        XCTAssertNil(counter.record(nowNs: 5 * second))
    }

    func testWindowClosesAtOneSecondWithTheFrameCount() {
        var counter = FrameRateCounter()
        XCTAssertNil(counter.record(nowNs: 0))
        for i in 1..<30 {
            XCTAssertNil(counter.record(nowNs: UInt64(i) * second / 30))
        }
        // Thirty-one observations span [0, 1 s] at 30 fps — the opening frame
        // plus one per interval — so the reading is 31, not 30. Asserted with
        // a tolerance rather than pinned exactly: the ±1 is the documented
        // counting convention, and a test that demanded 30 would be asserting
        // a bug.
        let fps = counter.record(nowNs: second)
        XCTAssertNotNil(fps)
        XCTAssertEqual(fps ?? 0, 30, accuracy: 1)
    }

    func testNothingIsReportedBeforeTheWindowElapses() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        for i in 1...59 {
            XCTAssertNil(
                counter.record(nowNs: UInt64(i) * 10_000_000),
                "600 ms in, there is nothing to report yet")
        }
    }

    func testSuccessiveWindowsEachReport() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        var readings: [Int] = []
        // Two full seconds at a steady 10 fps.
        for i in 1...20 {
            if let fps = counter.record(nowNs: UInt64(i) * second / 10) {
                readings.append(fps)
            }
        }
        XCTAssertEqual(readings.count, 2, "one reading per closed window")
        for fps in readings {
            XCTAssertEqual(fps, 10, accuracy: 1)
        }
        XCTAssertTrue(readings.allSatisfy { $0 > 0 }, "a steady stream never reads zero")
    }

    func testTheNextWindowAnchorsToTheObservationNotTheSchedule() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        // A slow stream: the closing frame lands well PAST one second. Two
        // observations across two seconds reads as 1 fps.
        XCTAssertEqual(counter.record(nowNs: 2 * second), 1)
        // The window that just closed re-anchored to 2 s, so this frame is
        // measured across the one second it actually spans. Had the anchor
        // advanced by a fixed window length instead, it would be divided by
        // two seconds and read as half the true rate.
        XCTAssertEqual(counter.record(nowNs: 3 * second), 1)
    }

    func testResetForgetsTheWindow() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        for i in 1...5 { _ = counter.record(nowNs: UInt64(i) * 100_000_000) }
        counter.reset()
        // Both sinks outlive one viewing session. Without the reset, the first
        // frame of the NEXT session closes a window opened during the previous
        // one — reporting a fraction of an fps across the idle gap.
        XCTAssertNil(
            counter.record(nowNs: 600 * second),
            "the first frame after a reset opens a window rather than closing one")
    }

    func testTheOpeningFrameCountsTowardItsWindow() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        // Two observations across one second: the frame that opened the window
        // and the one that closed it. Both count, so the reading is 2. This is
        // the whole of the documented ±1 convention, pinned on its smallest
        // case so a change to it cannot pass unnoticed.
        XCTAssertEqual(counter.record(nowNs: second), 2)
    }

    func testAWindowStartingAtTimestampZeroStillReports() {
        var counter = FrameRateCounter()
        // A `0` window-start sentinel would swallow this entirely: every frame
        // would look like the first one and the counter would never report.
        // The inline version being replaced had exactly that shape and only
        // survived because its clock never returns 0.
        XCTAssertNil(counter.record(nowNs: 0))
        XCTAssertNotNil(counter.record(nowNs: second))
    }

    func testSixtyFPSReportsSixty() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        var reading: Int?
        for i in 1...60 {
            if let fps = counter.record(nowNs: UInt64(i) * second / 60) { reading = fps }
        }
        XCTAssertNotNil(reading)
        XCTAssertEqual(reading ?? 0, 60, accuracy: 1)
    }
}
