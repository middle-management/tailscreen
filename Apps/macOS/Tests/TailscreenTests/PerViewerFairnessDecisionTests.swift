import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// Unit tests for the per-viewer fairness decisions extracted from
/// `TailscaleScreenShareServer` — `lossAttribution` (is one viewer the
/// problem, or is everyone suffering?) and `fairnessDecision` (who gets
/// throttled to keyframe-only, and what PLI count drives the global bitrate).
/// Pure functions, no tsnet, no encoder — same pattern as `AdaptiveBitrateTests`
/// and `ViewerLifecycleDecisionTests`.
final class PerViewerFairnessDecisionTests: XCTestCase {

    // MARK: - lossAttribution

    func testAllCleanIsHealthy() {
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 0, "b": 0, "c": 1]),
            .healthy)
    }

    func testEmptyIsHealthy() {
        XCTAssertEqual(TailscaleScreenShareServer.lossAttribution(pliCounts: [:]), .healthy)
    }

    func testOneBadOthersCleanIsIsolated() {
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 5, "b": 0, "c": 0]),
            .isolated(addr: "a", plis: 5))
    }

    func testOneBadAnotherMerelyNonzeroIsWidespread() {
        // "b" is only 1 PLI (below threshold) but not perfectly clean, so
        // this is NOT the isolated case — a global cut is warranted.
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 5, "b": 1, "c": 0]),
            .widespread(worstPLIs: 5))
    }

    func testTwoBadIsWidespread() {
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 5, "b": 4, "c": 0]),
            .widespread(worstPLIs: 5))
    }

    func testSingleViewerBadIsWidespreadNoPeersRule() {
        // With one viewer there is no "everyone else" to protect, so an
        // isolated verdict would be meaningless — it stays widespread,
        // identical to today's global cut.
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 5]),
            .widespread(worstPLIs: 5))
    }

    func testThresholdBoundaryIsNotOver() {
        // Exactly at threshold (2) is not "over" — mirrors
        // AdaptiveBitrateTests.testNoCutAtOrBelowThreshold.
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 2, "b": 0]),
            .healthy)
        // 3 is over, others clean → isolated.
        XCTAssertEqual(
            TailscaleScreenShareServer.lossAttribution(pliCounts: ["a": 3, "b": 0]),
            .isolated(addr: "a", plis: 3))
    }

    // MARK: - fairnessDecision

    func testHealthyThrottlesNobodyAndZeroGlobalInput() {
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["a": 0, "b": 1], currentlyThrottled: [])
        XCTAssertEqual(d, .init(throttle: [], globalBitrateInput: 1))
    }

    func testIsolatedThrottlesBadViewerAndExcludesItFromGlobal() {
        // The isolated viewer is throttled and excluded from the global max,
        // so `.isolated` never triggers a global cut — the healthy viewers
        // keep their bitrate.
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["bad": 9, "ok1": 0, "ok2": 0], currentlyThrottled: [])
        XCTAssertEqual(d.throttle, ["bad"])
        XCTAssertEqual(d.globalBitrateInput, 0)
    }

    func testIsolatedRenewedWhileStillLosing() {
        // Already throttled and still over threshold → stays throttled.
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["bad": 7, "ok": 0], currentlyThrottled: ["bad"])
        XCTAssertEqual(d.throttle, ["bad"])
        XCTAssertEqual(d.globalBitrateInput, 0)
    }

    func testThrottleExpiresAfterCleanWindow() {
        // Previously throttled, now clean → not renewed (expires), and it
        // rejoins the global input (which is 0 here anyway).
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["was": 0, "ok": 0], currentlyThrottled: ["was"])
        XCTAssertEqual(d.throttle, [])
        XCTAssertEqual(d.globalBitrateInput, 0)
    }

    func testWidespreadPassesTrueMaxThroughWhenNobodyThrottled() {
        // Two bad viewers, none throttled → today's behavior: throttle nobody
        // new, feed the true max to the global decision.
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["a": 5, "b": 4, "c": 0], currentlyThrottled: [])
        XCTAssertEqual(d.throttle, [])
        XCTAssertEqual(d.globalBitrateInput, 5)
    }

    func testWidespreadExcludesAlreadyThrottledViewerFromGlobal() {
        // A viewer already in keyframe-only mode is deliberately frame-
        // skipped, so its PLIs must not drive the global cut even when
        // another viewer makes the window widespread. Here "b" (not
        // throttled) drives the input; "a"'s larger count is excluded.
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["a": 9, "b": 4, "c": 0], currentlyThrottled: ["a"])
        XCTAssertEqual(d.throttle, ["a"])  // renewed (still losing)
        XCTAssertEqual(d.globalBitrateInput, 4)
    }

    func testSingleBadViewerDrivesGlobalNotThrottle() {
        // No-peers rule from lossAttribution: a lone viewer losing is
        // widespread, so it drives the global cut rather than being throttled.
        let d = TailscaleScreenShareServer.fairnessDecision(
            pliCounts: ["only": 6], currentlyThrottled: [])
        XCTAssertEqual(d.throttle, [])
        XCTAssertEqual(d.globalBitrateInput, 6)
    }
}
