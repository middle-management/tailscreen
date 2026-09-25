import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsTransportSampler` — the cadence gate in front of
/// `transport.summary`, driven on an explicit clock. Firing too often is a
/// per-packet firehose that evicts the handshake from the ring; never firing
/// makes a bundle with no rows look clean. Both directions pinned at the
/// exact boundary.
final class DiagnosticsTransportSamplerTests: XCTestCase {

    private let window: UInt64 = 5_000_000_000

    func testFirstTickOpensTheWindowWithoutFiring() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        XCTAssertNil(sampler.windowClosed(nowNs: 1_000))
    }

    func testFiresExactlyAtTheBoundaryAndNotBefore() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 1_000)
        XCTAssertNil(sampler.windowClosed(nowNs: 1_000 + window - 1), "one ns short is inside")
        XCTAssertEqual(sampler.windowClosed(nowNs: 1_000 + window), window, "the boundary closes it")
    }

    /// Reports the measured window, not the nominal one, and re-anchors the
    /// next window at the late reading — so two late ticks don't double-fire.
    func testLateTickReportsMeasuredWindowAndReanchors() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 0)
        XCTAssertEqual(sampler.windowClosed(nowNs: window + 700), window + 700)
        XCTAssertNil(
            sampler.windowClosed(nowNs: window + 800),
            "the window re-opened at the late tick, not at the nominal boundary")
        XCTAssertEqual(sampler.windowClosed(nowNs: 2 * window + 700), window)
    }

    /// Wrapped subtraction would otherwise read a backward clock step as a
    /// window centuries long and fire on it.
    func testBackwardClockReanchorsWithoutFiring() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 10 * window)
        XCTAssertNil(sampler.windowClosed(nowNs: 3 * window), "backward: no window closed")
        XCTAssertNil(sampler.windowClosed(nowNs: 3 * window + window - 1), "re-anchored at the step")
        XCTAssertEqual(sampler.windowClosed(nowNs: 4 * window), window)
    }

    func testResetForgetsTheOpenWindow() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 0)
        sampler.reset()
        XCTAssertNil(sampler.windowClosed(nowNs: 100 * window), "a reset sampler opens, never fires")
        XCTAssertEqual(sampler.windowClosed(nowNs: 101 * window), window)
    }

    func testZeroWindowIsClampedNotHonoured() {
        var sampler = DiagnosticsTransportSampler(windowNs: 0)
        XCTAssertEqual(sampler.windowNs, 1)
        XCTAssertNil(sampler.windowClosed(nowNs: 5))
        XCTAssertNil(sampler.windowClosed(nowNs: 5), "same instant: no window has elapsed")
        XCTAssertEqual(sampler.windowClosed(nowNs: 6), 1)
    }

    /// Matches the sharer's adaptive-bitrate window so rows line up across sides.
    func testDefaultWindowIsFiveSeconds() {
        XCTAssertEqual(DiagnosticsTransportSampler.defaultWindowNs, 5_000_000_000)
        XCTAssertEqual(DiagnosticsTransportSampler().windowNs, 5_000_000_000)
    }
}
