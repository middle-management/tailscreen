import XCTest

@testable import TailscreenProtocol

/// `PortalCapturePlan` — the decisions the ScreenCast-portal capture backend
/// makes, which is every decision in it that can be *wrong* rather than merely
/// unexercised.
///
/// This suite carries more weight than its size suggests. The portal has no
/// headless path and cannot ever have one, so unlike X11 capture (whose CI leg
/// grabs a real Xvfb root) nothing downstream of these functions is gated
/// anywhere. If a branch here is wrong, the first person to find out is a
/// person sharing their screen.
final class PortalCapturePlanTests: XCTestCase {

    // MARK: Stream conditions

    /// The edge worth the whole file. Someone pressing "stop sharing" in their
    /// compositor must reach `onUserStopped`, because `onUnexpectedExit` makes
    /// the server respawn the backend — and respawning THIS backend means a
    /// fresh consent dialog in the face of somebody who just said stop.
    func testTheProducerGoingAwayIsAUserStopAndNotAFailure() {
        XCTAssertEqual(PortalCapturePlan.action(for: .ended("node removed")), .userStopped)
    }

    func testAGenuineStreamFailureIsReportedAsAnUnexpectedExit() {
        guard case .unexpectedExit(let reason) = PortalCapturePlan.action(for: .failed("no buffers"))
        else {
            return XCTFail("a failed stream must reach onUnexpectedExit")
        }
        XCTAssertTrue(reason.contains("no buffers"), "the detail must survive: \(reason)")
    }

    /// The reason string is not free text: `classifyHelperExit` reads markers
    /// out of it. `source-gone:` and `permanent:` both suppress the respawn,
    /// and a respawn is exactly what should happen here — the host keeps the
    /// negotiated session, so rebuilding the stream costs no second dialog.
    func testAStreamFailureStaysRetryableRatherThanSuppressingTheRespawn() {
        guard case .unexpectedExit(let reason) = PortalCapturePlan.action(for: .failed("pipe broke"))
        else {
            return XCTFail("expected an unexpected-exit action")
        }
        XCTAssertFalse(reason.contains("source-gone:"), reason)
        XCTAssertFalse(reason.contains("permanent:"), reason)
    }

    func testConnectingAndStreamingReportNothing() {
        XCTAssertEqual(PortalCapturePlan.action(for: .connecting), .ignore)
        XCTAssertEqual(PortalCapturePlan.action(for: .streaming), .ignore)
    }

    // MARK: Encodable size

    func testOddDimensionsAreRoundedDownToEven() {
        let size = PortalCapturePlan.encodableSize(width: 1919, height: 1081)
        XCTAssertEqual(size?.width, 1918)
        XCTAssertEqual(size?.height, 1080)
    }

    func testEvenDimensionsAreLeftAlone() {
        let size = PortalCapturePlan.encodableSize(width: 1920, height: 1080)
        XCTAssertEqual(size?.width, 1920)
        XCTAssertEqual(size?.height, 1080)
    }

    /// A 1-pixel-tall window rounds to zero, and a zero-height encoder is not a
    /// smaller share — it is an `avcodec_open2` failure or a divide by zero
    /// somewhere in the conversion.
    func testADimensionThatRoundsToZeroIsRejected() {
        XCTAssertNil(PortalCapturePlan.encodableSize(width: 1920, height: 1))
        XCTAssertNil(PortalCapturePlan.encodableSize(width: 0, height: 1080))
        XCTAssertNil(PortalCapturePlan.encodableSize(width: -4, height: 1080))
    }

    // MARK: Frame routing

    func testAMatchingFrameIsEncoded() {
        let action = PortalCapturePlan.frameAction(
            frame: (1920, 1080), encoder: (1920, 1080),
            lastRebuildNs: 0, nowNs: 10_000_000_000)
        XCTAssertEqual(action, .encode)
    }

    /// An odd-sized frame against an even-rounded encoder is the ORDINARY
    /// case, not a mismatch: the encoder was opened at the rounded size in the
    /// first place. Treating it as a resize would rebuild the encoder on every
    /// single frame of a share whose window happens to be an odd width.
    func testAnOddFrameMatchesTheEvenEncoderItWasRoundedTo() {
        let action = PortalCapturePlan.frameAction(
            frame: (1919, 1081), encoder: (1918, 1080),
            lastRebuildNs: 0, nowNs: 10_000_000_000)
        XCTAssertEqual(action, .encode)
    }

    func testTheFirstFrameBuildsAnEncoder() {
        let action = PortalCapturePlan.frameAction(
            frame: (1280, 720), encoder: nil, lastRebuildNs: nil, nowNs: 0)
        XCTAssertEqual(action, .rebuildEncoder(width: 1280, height: 720))
    }

    func testAResizedStreamRebuildsTheEncoderAtTheNewSize() {
        let action = PortalCapturePlan.frameAction(
            frame: (1280, 720), encoder: (1920, 1080),
            lastRebuildNs: 0, nowNs: 10_000_000_000)
        XCTAssertEqual(action, .rebuildEncoder(width: 1280, height: 720))
    }

    /// Dragging a window by its corner renegotiates the format continuously.
    /// Rebuilding per frame would put the whole share inside `avcodec_open2`
    /// for as long as the drag lasts.
    func testARapidlyResizingWindowDoesNotRebuildOnEveryFrame() {
        let action = PortalCapturePlan.frameAction(
            frame: (1281, 721), encoder: (1920, 1080),
            lastRebuildNs: 1_000_000_000,
            nowNs: 1_000_000_000 + PortalCapturePlan.minRebuildIntervalNs - 1)
        guard case .drop = action else {
            return XCTFail("expected the rebuild to be debounced, got \(action)")
        }
    }

    /// The other half of the debounce, and the one that would strand a share:
    /// once the interval has elapsed the rebuild must actually happen, or a
    /// user who resized their window once is left looking at a frozen picture.
    func testTheRebuildHappensOnceTheDebounceElapses() {
        let action = PortalCapturePlan.frameAction(
            frame: (1280, 720), encoder: (1920, 1080),
            lastRebuildNs: 1_000_000_000,
            nowNs: 1_000_000_000 + PortalCapturePlan.minRebuildIntervalNs)
        XCTAssertEqual(action, .rebuildEncoder(width: 1280, height: 720))
    }

    /// The debounce is measured from the last REBUILD, never from the last
    /// mismatch. Timing it from the mismatch restarts the clock on every
    /// dropped frame, so a window resized continuously for longer than the
    /// interval would never rebuild at all — the share stays frozen after the
    /// user lets go, which is the exact failure the debounce exists to avoid
    /// being worth having.
    func testASustainedResizeStillRebuildsRatherThanStarvingForever() {
        var lastRebuild: UInt64 = 0
        var rebuilds = 0
        // 60 frames at 60 fps — one second of continuous dragging.
        for frameIndex in 0..<60 {
            let now = UInt64(frameIndex) * 16_666_666
            let action = PortalCapturePlan.frameAction(
                frame: (1280 + frameIndex * 2, 720), encoder: (1920, 1080),
                lastRebuildNs: lastRebuild, nowNs: now)
            if case .rebuildEncoder = action {
                rebuilds += 1
                lastRebuild = now
            }
        }
        XCTAssertGreaterThan(rebuilds, 0, "a sustained resize must eventually rebuild")
        XCTAssertLessThanOrEqual(rebuilds, 3, "but not once per frame — got \(rebuilds)")
    }

    func testAnUnusableFrameGeometryIsDroppedRatherThanEncoded() {
        let action = PortalCapturePlan.frameAction(
            frame: (0, 0), encoder: (1920, 1080), lastRebuildNs: nil, nowNs: 0)
        guard case .drop = action else {
            return XCTFail("a zero-sized frame must be dropped, got \(action)")
        }
    }

    /// A degenerate frame must not be allowed to trigger a rebuild either —
    /// that would replace a working encoder with one that cannot open.
    func testAnUnusableGeometryDoesNotRebuildTheEncoder() {
        let action = PortalCapturePlan.frameAction(
            frame: (1920, 1), encoder: nil, lastRebuildNs: nil, nowNs: 0)
        guard case .drop = action else {
            return XCTFail("expected a drop, got \(action)")
        }
    }
}
