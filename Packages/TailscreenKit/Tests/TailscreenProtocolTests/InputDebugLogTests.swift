import XCTest

@testable import TailscreenProtocol

/// `InputDebugLog.Sampler` — the 1 Hz windowing behind `TAILSCREEN_DEBUG_INPUT=1`.
/// Must not lie: a window that never closes (or closes every event) hides the
/// stalled-vs-healthy distinction it exists to show. Driven on an explicit clock.
final class InputDebugLogTests: XCTestCase {
    private let second = InputDebugLog.Sampler.windowNs

    func testNoSummaryBeforeTheWindowCloses() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(1_000_000, nowNs: 0))
        XCTAssertNil(sampler.note(1_000_000, nowNs: second / 2))
    }

    func testSummaryAtTheWindowBoundaryCarriesCountMeanAndMax() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(2_000_000, nowNs: 0))
        XCTAssertNil(sampler.note(4_000_000, nowNs: second / 2))
        let summary = sampler.note(6_000_000, nowNs: second)
        XCTAssertEqual(summary, "n=3 mean=4.0ms max=6.0ms")
    }

    func testWindowRestartsAfterASummary() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(1_000_000, nowNs: 0))
        XCTAssertNotNil(sampler.note(1_000_000, nowNs: second))
        XCTAssertNil(sampler.note(9_000_000, nowNs: second + 1))
        XCTAssertEqual(
            sampler.note(9_000_000, nowNs: 2 * second + 1), "n=2 mean=9.0ms max=9.0ms")
    }

    /// Window opens on the first sample, not at construction: a viewer holding
    /// a grant idle for a minute must not have its first burst averaged against it.
    func testWindowOpensOnFirstSampleNotAtConstruction() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(1_000_000, nowNs: 60 * second))
        XCTAssertNil(sampler.note(1_000_000, nowNs: 60 * second + second / 2))
        XCTAssertNotNil(sampler.note(1_000_000, nowNs: 61 * second))
    }

    /// A backward clock step must not wrap into a huge elapsed, satisfying the window check forever or never.
    func testBackwardsClockDoesNotWrapTheWindow() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(1_000_000, nowNs: 10 * second))
        XCTAssertNil(sampler.note(1_000_000, nowNs: 9 * second), "earlier `now` closes nothing")
        XCTAssertNotNil(sampler.note(1_000_000, nowNs: 11 * second))
    }

    func testMillisecondFormatting() {
        XCTAssertEqual(InputDebugLog.ms(0), "0.0ms")
        XCTAssertEqual(InputDebugLog.ms(1_500_000), "1.5ms")
        XCTAssertEqual(InputDebugLog.ms(4_812_300_000), "4812.3ms")
    }
}
