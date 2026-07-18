import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Unit tests for the pure helper-restart decisions extracted from
/// `TailscaleScreenShareServer.onUnexpectedExit` and the idle-sweep watchdog:
/// exit-reason classification, the 3-in-30s sliding crash budget, and the
/// hung-helper liveness predicate. These guard the stuck-recording-badge /
/// restart-loop behavior that can't run on CI (it needs a real capture
/// helper), so the decision math is covered here instead.
final class HelperRestartDecisionTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    // MARK: - classifyHelperExit

    func testReplaydSlotRefusalIsNotRetried() {
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(
                reason: "fatal: stream error -3805"),
            .slotRefused)
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(
                reason: "The application connection Being Interrupted"),
            .slotRefused)
    }

    func testPermanentMarkerIsNotRetried() {
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(
                reason: "fatal: permanent: encoder cannot start"),
            .permanent)
    }

    func testSourceGoneMarkerIsClassifiedSeparately() {
        // The shared window/display/app closing is non-retryable but is an
        // expected stop, not an error — it gets its own disposition so the UI
        // can show a gentle notice instead of an error alert.
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(
                reason: "fatal: source-gone: windowNotFound(Optional(1234))"),
            .sourceGone)
    }

    func testSlotRefusalWinsOverSourceGone() {
        // -3805 is still checked first: a slot refusal is the more actionable
        // signal even if the reason also mentions a missing source.
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(
                reason: "source-gone: -3805 being interrupted"),
            .slotRefused)
    }

    func testSlotRefusalWinsOverPermanentMarker() {
        // -3805 is checked first — it carries the more actionable message
        // (another instance holds the slot).
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(
                reason: "permanent: -3805"),
            .slotRefused)
    }

    func testOrdinaryCrashIsRetryable() {
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(reason: "exit code 11"),
            .retryable)
        XCTAssertEqual(
            TailscaleScreenShareServer.classifyHelperExit(reason: ""),
            .retryable)
    }

    // MARK: - slidingWindowCrashCount

    func testCountsCrashesInsideWindow() {
        var stamps: [UInt64] = []
        XCTAssertEqual(
            TailscaleScreenShareServer.slidingWindowCrashCount(&stamps, appending: 100 * s), 1)
        XCTAssertEqual(
            TailscaleScreenShareServer.slidingWindowCrashCount(&stamps, appending: 110 * s), 2)
        XCTAssertEqual(
            TailscaleScreenShareServer.slidingWindowCrashCount(&stamps, appending: 120 * s), 3)
        // Third crash is still within budget (give up only *above*
        // maxHelperCrashesPerWindow).
        XCTAssertLessThanOrEqual(3, TailscaleScreenShareServer.maxHelperCrashesPerWindow)
    }

    func testFourthCrashInWindowExhaustsBudget() {
        var stamps: [UInt64] = []
        for t in [100, 105, 110, 115] {
            _ = TailscaleScreenShareServer.slidingWindowCrashCount(
                &stamps, appending: UInt64(t) * s)
        }
        XCTAssertGreaterThan(stamps.count, TailscaleScreenShareServer.maxHelperCrashesPerWindow)
    }

    func testOldCrashesAgeOutOfWindow() {
        var stamps: [UInt64] = []
        for t in [100, 105, 110] {
            _ = TailscaleScreenShareServer.slidingWindowCrashCount(
                &stamps, appending: UInt64(t) * s)
        }
        // 45 s later the three earlier crashes are outside the 30 s window;
        // a fresh crash counts as #1 again.
        XCTAssertEqual(
            TailscaleScreenShareServer.slidingWindowCrashCount(&stamps, appending: 155 * s), 1)
        XCTAssertEqual(stamps, [155 * s])
    }

    func testCrashExactlyAtWindowEdgeStillCounts() {
        // Pruning is strictly greater-than: a crash exactly `windowNs` old
        // still counts against the budget.
        var stamps: [UInt64] = [100 * s]
        XCTAssertEqual(
            TailscaleScreenShareServer.slidingWindowCrashCount(&stamps, appending: 130 * s), 2)
    }

    // MARK: - helperLooksHung

    func testNoHelperYetNeverLooksHung() {
        // lastActivityNs == 0 means no helper has ever produced output.
        XCTAssertFalse(
            TailscaleScreenShareServer.helperLooksHung(
                lastActivityNs: 0, nowNs: 1000 * s, timeoutNs: 15 * s))
    }

    func testRecentActivityIsNotHung() {
        XCTAssertFalse(
            TailscaleScreenShareServer.helperLooksHung(
                lastActivityNs: 95 * s, nowNs: 100 * s, timeoutNs: 15 * s))
    }

    func testSilencePastTimeoutIsHung() {
        XCTAssertTrue(
            TailscaleScreenShareServer.helperLooksHung(
                lastActivityNs: 80 * s, nowNs: 100 * s, timeoutNs: 15 * s))
    }

    func testExactlyAtTimeoutIsNotYetHung() {
        XCTAssertFalse(
            TailscaleScreenShareServer.helperLooksHung(
                lastActivityNs: 85 * s, nowNs: 100 * s, timeoutNs: 15 * s))
    }
}
