import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// Unit tests for the adaptive-bitrate decision. Pure function, no tsnet, no
/// encoder — exercises the loss/recovery math and asymmetric hysteresis that
/// the live sweep (`adaptiveBitrateSweep`) drives. An end-to-end version isn't
/// viable: the sweep intentionally no-ops without a capture-helper attached.
final class AdaptiveBitrateTests: XCTestCase {
    private let baseline = 10_000_000  // 10 Mbps
    private let s: UInt64 = 1_000_000_000

    private func decide(
        plis: Int, current: Int, elapsed: UInt64
    ) -> Int? {
        TailscaleScreenShareServer.nextAdaptiveBitrate(
            worstPLIs: plis, current: current, baseline: baseline, elapsedSinceChangeNs: elapsed)
    }

    func testHoldsWhenNoBaselineYet() {
        // baseline 0 == encoder not configured; never adapt.
        XCTAssertNil(
            TailscaleScreenShareServer.nextAdaptiveBitrate(
                worstPLIs: 99, current: 0, baseline: 0, elapsedSinceChangeNs: 60 * s))
    }

    func testCutsByQuarterOnSustainedLoss() {
        // 3 PLIs > threshold(2), down-hysteresis (5 s) elapsed, above floor.
        XCTAssertEqual(decide(plis: 3, current: baseline, elapsed: 5 * s), 7_500_000)
    }

    func testNoCutBeforeDownHysteresis() {
        XCTAssertNil(decide(plis: 5, current: baseline, elapsed: 4 * s))
    }

    func testNoCutAtOrBelowThreshold() {
        // Exactly at threshold (2) does not trigger; needs strictly greater.
        XCTAssertNil(decide(plis: 2, current: baseline, elapsed: 30 * s))
    }

    func testCutClampsToFloor() {
        // floor = max(30% of baseline, 500 kbps) = 3 Mbps. A 25% cut from
        // 3.5 Mbps would be 2.625 Mbps, so it clamps up to the floor.
        XCTAssertEqual(decide(plis: 9, current: 3_500_000, elapsed: 6 * s), 3_000_000)
    }

    func testNoCutWhenAlreadyAtFloor() {
        XCTAssertNil(decide(plis: 9, current: 3_000_000, elapsed: 6 * s))
    }

    func testRecoversAfterCleanWindow() {
        // 0 PLIs, up-hysteresis (10 s) elapsed, below baseline → +10%.
        XCTAssertEqual(decide(plis: 0, current: 5_000_000, elapsed: 10 * s), 5_500_000)
    }

    func testNoRecoveryBeforeUpHysteresis() {
        XCTAssertNil(decide(plis: 0, current: 5_000_000, elapsed: 9 * s))
    }

    func testRecoveryUsesMinStepWhenCurrentSmall() {
        // +10% of 600k is 60k, below the 100 kbps minimum step.
        XCTAssertEqual(decide(plis: 0, current: 600_000, elapsed: 12 * s), 700_000)
    }

    func testRecoveryCapsAtBaseline() {
        XCTAssertEqual(decide(plis: 0, current: 9_950_000, elapsed: 12 * s), baseline)
    }

    func testNoRecoveryAtBaseline() {
        XCTAssertNil(decide(plis: 0, current: baseline, elapsed: 30 * s))
    }

    func testClampsDownWhenCurrentExceedsBaseline() {
        // A mid-share ceiling drop can park `current` above the new baseline,
        // where neither normal arm fires on a loss-free link. Clamp-down
        // returns baseline immediately, no hysteresis, and wins over the
        // loss arm too.
        XCTAssertEqual(decide(plis: 0, current: 12_000_000, elapsed: 0), baseline)
        XCTAssertEqual(decide(plis: 9, current: 20_000_000, elapsed: 30 * s), baseline)
    }

    func testCeilingClampedBaselineDrivesFloorAndCut() {
        // baseline = min(computeBitrate, ceiling); 1920x1080@30fps ≈ 4.98 Mbps, clamped to 2 Mbps.
        let anchor = VideoEncoder.computeBitrate(width: 1920, height: 1080, fps: 30, bitsPerPixel: 0.08)
        XCTAssertGreaterThan(anchor, 2_000_000)
        let clamped = min(anchor, 2_000_000)
        // Floor/cut/recovery all derive from the clamped baseline, not the raw anchor.
        XCTAssertEqual(TransportTuning.adaptiveBitrateFloor(baseline: clamped), 600_000)
        XCTAssertEqual(
            TailscaleScreenShareServer.nextAdaptiveBitrate(
                worstPLIs: 3, current: clamped, baseline: clamped, elapsedSinceChangeNs: 5 * s),
            1_500_000)
        XCTAssertEqual(
            TailscaleScreenShareServer.nextAdaptiveBitrate(
                worstPLIs: 0, current: 1_900_000, baseline: clamped, elapsedSinceChangeNs: 12 * s),
            2_000_000)
    }
}
