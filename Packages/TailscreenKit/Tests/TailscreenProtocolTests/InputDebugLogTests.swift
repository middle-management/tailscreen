import XCTest

@testable import TailscreenProtocol

/// Coverage for `InputDebugLog.Sampler`, the 1 Hz windowing behind the
/// `TAILSCREEN_DEBUG_INPUT=1` readout.
///
/// It is only a diagnostic, but a diagnostic that lies is worse than none:
/// the whole reason it exists is to tell a stalled input path from a healthy
/// one, and a window that never closes (or closes every event) hides exactly
/// the difference somebody turned it on to see. Driven on an explicit clock,
/// so none of this sleeps.
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

    /// The window reopens on the next sample, so a long session prints one
    /// line a second rather than one line and then silence.
    func testWindowRestartsAfterASummary() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(1_000_000, nowNs: 0))
        XCTAssertNotNil(sampler.note(1_000_000, nowNs: second))
        XCTAssertNil(sampler.note(9_000_000, nowNs: second + 1))
        XCTAssertEqual(
            sampler.note(9_000_000, nowNs: 2 * second + 1), "n=2 mean=9.0ms max=9.0ms")
    }

    /// The window opens on the FIRST sample, not at construction: a viewer
    /// that holds a grant for a minute before touching the mouse must not have
    /// its first burst averaged against that idle minute.
    func testWindowOpensOnFirstSampleNotAtConstruction() {
        var sampler = InputDebugLog.Sampler()
        // First sample arrives a full minute in; it opens the window rather
        // than immediately closing one that started at zero.
        XCTAssertNil(sampler.note(1_000_000, nowNs: 60 * second))
        XCTAssertNil(sampler.note(1_000_000, nowNs: 60 * second + second / 2))
        XCTAssertNotNil(sampler.note(1_000_000, nowNs: 61 * second))
    }

    /// A clock that appears to move backwards must not wrap into an enormous
    /// elapsed — which would satisfy the window check forever, or never again.
    func testBackwardsClockDoesNotWrapTheWindow() {
        var sampler = InputDebugLog.Sampler()
        XCTAssertNil(sampler.note(1_000_000, nowNs: 10 * second))
        XCTAssertNil(sampler.note(1_000_000, nowNs: 9 * second), "earlier `now` closes nothing")
        // And the sampler still works once the clock is sane again.
        XCTAssertNotNil(sampler.note(1_000_000, nowNs: 11 * second))
    }

    func testMillisecondFormatting() {
        XCTAssertEqual(InputDebugLog.ms(0), "0.0ms")
        XCTAssertEqual(InputDebugLog.ms(1_500_000), "1.5ms")
        XCTAssertEqual(InputDebugLog.ms(4_812_300_000), "4812.3ms")
    }
}
