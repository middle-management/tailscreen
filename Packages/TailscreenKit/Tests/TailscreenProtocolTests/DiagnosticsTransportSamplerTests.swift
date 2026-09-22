import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsTransportSampler` — the cadence gate in front of
/// `transport.summary`, driven on an explicit clock.
///
/// The failure this exists to prevent is silent in both directions. Firing
/// too often is the per-packet firehose the recorder's rules forbid: at the
/// viewer's tick rate a zero-length window would push the handshake out of
/// the ring in under a minute. Never firing is the gap the summary was added
/// to close: a bundle with no rows at all looks exactly like a clean one. So
/// the ticks that fire and the ticks that do not are both pinned, on the
/// exact boundary.
final class DiagnosticsTransportSamplerTests: XCTestCase {

    private let window: UInt64 = 5_000_000_000

    /// The first call opens the window and does not fire — a summary at the
    /// moment of admission would carry only zeros.
    func testFirstTickOpensTheWindowWithoutFiring() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        XCTAssertNil(sampler.windowClosed(nowNs: 1_000))
    }

    /// Nothing inside the window; the boundary itself fires, carrying the
    /// window it actually measured.
    func testFiresExactlyAtTheBoundaryAndNotBefore() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 1_000)
        XCTAssertNil(sampler.windowClosed(nowNs: 1_000 + window - 1), "one ns short is inside")
        XCTAssertEqual(sampler.windowClosed(nowNs: 1_000 + window), window, "the boundary closes it")
    }

    /// A late tick reports the window it measured, not the nominal one, and
    /// the next window opens at that late reading — so two late ticks do not
    /// fire twice for one window's worth of traffic.
    func testLateTickReportsMeasuredWindowAndReanchors() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 0)
        XCTAssertEqual(sampler.windowClosed(nowNs: window + 700), window + 700)
        XCTAssertNil(
            sampler.windowClosed(nowNs: window + 800),
            "the window re-opened at the late tick, not at the nominal boundary")
        XCTAssertEqual(sampler.windowClosed(nowNs: 2 * window + 700), window)
    }

    /// A clock that reads earlier than the open window re-anchors and does
    /// not fire. Wrapped subtraction would otherwise read a backward step as
    /// a window several hundred years long and fire on it.
    func testBackwardClockReanchorsWithoutFiring() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 10 * window)
        XCTAssertNil(sampler.windowClosed(nowNs: 3 * window), "backward: no window closed")
        XCTAssertNil(sampler.windowClosed(nowNs: 3 * window + window - 1), "re-anchored at the step")
        XCTAssertEqual(sampler.windowClosed(nowNs: 4 * window), window)
    }

    /// `reset` forgets the open window: the next tick opens a fresh one and
    /// does not fire, however much time passed.
    func testResetForgetsTheOpenWindow() {
        var sampler = DiagnosticsTransportSampler(windowNs: window)
        _ = sampler.windowClosed(nowNs: 0)
        sampler.reset()
        XCTAssertNil(sampler.windowClosed(nowNs: 100 * window), "a reset sampler opens, never fires")
        XCTAssertEqual(sampler.windowClosed(nowNs: 101 * window), window)
    }

    /// A zero window is clamped rather than firing on every tick.
    func testZeroWindowIsClampedNotHonoured() {
        var sampler = DiagnosticsTransportSampler(windowNs: 0)
        XCTAssertEqual(sampler.windowNs, 1)
        XCTAssertNil(sampler.windowClosed(nowNs: 5))
        XCTAssertNil(sampler.windowClosed(nowNs: 5), "same instant: no window has elapsed")
        XCTAssertEqual(sampler.windowClosed(nowNs: 6), 1)
    }

    /// The default matches the sharer's adaptive-bitrate window, so one
    /// sharer row per viewer lines up with one viewer row.
    func testDefaultWindowIsFiveSeconds() {
        XCTAssertEqual(DiagnosticsTransportSampler.defaultWindowNs, 5_000_000_000)
        XCTAssertEqual(DiagnosticsTransportSampler().windowNs, 5_000_000_000)
    }
}
