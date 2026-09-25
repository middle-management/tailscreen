import XCTest

@testable import TailscreenViewer

/// The viewer HUD's frames-per-second window. Worth testing rather than
/// eyeballing: every failure mode here is a plausible-looking wrong number,
/// not a crash.
final class FrameRateCounterTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testFirstFrameOpensTheWindowWithoutReporting() {
        var counter = FrameRateCounter()
        // Reporting here would divide by a zero epoch, giving a
        // several-billion-fps reading on the first frame of every session.
        XCTAssertNil(counter.record(nowNs: 5 * second))
    }

    func testWindowClosesAtOneSecondWithTheFrameCount() {
        var counter = FrameRateCounter()
        XCTAssertNil(counter.record(nowNs: 0))
        for i in 1..<30 {
            XCTAssertNil(counter.record(nowNs: UInt64(i) * second / 30))
        }
        // 31 observations span [0, 1s] at 30fps (opening frame + one per
        // interval); the documented ±1 counting convention, not a bug.
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
        // Slow stream: closing frame lands well past 1s, so 2 obs over 2s = 1fps.
        XCTAssertEqual(counter.record(nowNs: 2 * second), 1)
        // Anchor re-anchors to 2s, so this measures the 1s it actually spans —
        // a fixed-length anchor would divide by 2s and read half the true rate.
        XCTAssertEqual(counter.record(nowNs: 3 * second), 1)
    }

    func testResetForgetsTheWindow() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        for i in 1...5 { _ = counter.record(nowNs: UInt64(i) * 100_000_000) }
        counter.reset()
        // Without reset, the next session's first frame would close the
        // previous session's window, reporting a fraction of an fps.
        XCTAssertNil(
            counter.record(nowNs: 600 * second),
            "the first frame after a reset opens a window rather than closing one")
    }

    func testTheOpeningFrameCountsTowardItsWindow() {
        var counter = FrameRateCounter()
        _ = counter.record(nowNs: 0)
        // Both the opening and closing frame count, so this is 2 — the
        // documented ±1 convention on its smallest case.
        XCTAssertEqual(counter.record(nowNs: second), 2)
    }

    func testAWindowStartingAtTimestampZeroStillReports() {
        var counter = FrameRateCounter()
        // A `0` window-start sentinel would make every frame look like the
        // first one, so the counter would never report.
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
