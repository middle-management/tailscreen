import XCTest

@testable import TailscreenProtocol

/// Tests for `WindowsPointerMapping` — the normalized-coordinate → `SendInput`
/// arithmetic behind remote control on Windows. Multi-monitor bugs here are
/// invisible on a single-monitor dev box, so they're pinned here instead.
final class WindowsPointerMappingTests: XCTestCase {
    private let hd = WindowsPointerMapping.ScreenRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: normalized → screen

    func testCornersMapToTheRegionsCorners() {
        let topLeft = WindowsPointerMapping.screenPoint(normalizedX: 0, normalizedY: 0, in: hd)
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0)

        // The last addressable pixel, not the width.
        let bottomRight = WindowsPointerMapping.screenPoint(normalizedX: 1, normalizedY: 1, in: hd)
        XCTAssertEqual(bottomRight.x, 1919)
        XCTAssertEqual(bottomRight.y, 1079)
    }

    func testRegionOriginIsAdded() {
        // Normalized point is relative to the window, not the screen.
        let window = WindowsPointerMapping.ScreenRect(x: 300, y: 200, width: 800, height: 600)
        let middle = WindowsPointerMapping.screenPoint(
            normalizedX: 0.5, normalizedY: 0.5, in: window)
        XCTAssertEqual(middle.x, 300 + 400)  // (800-1)*0.5 = 399.5, rounds to 400
        XCTAssertEqual(middle.y, 200 + 300)  // (600-1)*0.5 = 299.5, rounds to 300
    }

    func testOutOfRangeIsClampedNotExtrapolated() {
        // Wire-supplied; must not place the pointer outside the visible region.
        let low = WindowsPointerMapping.screenPoint(normalizedX: -5, normalizedY: -0.001, in: hd)
        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)

        let high = WindowsPointerMapping.screenPoint(normalizedX: 12, normalizedY: 1.5, in: hd)
        XCTAssertEqual(high.x, 1919)
        XCTAssertEqual(high.y, 1079)
    }

    func testNonFiniteMapsToTheOrigin() {
        let nan = WindowsPointerMapping.screenPoint(
            normalizedX: .nan, normalizedY: .infinity, in: hd)
        XCTAssertEqual(nan.x, 0)
        XCTAssertEqual(nan.y, 0)
    }

    func testDegenerateRegionDoesNotTrap() {
        let sliver = WindowsPointerMapping.ScreenRect(x: 10, y: 20, width: 1, height: 0)
        let point = WindowsPointerMapping.screenPoint(normalizedX: 1, normalizedY: 1, in: sliver)
        XCTAssertEqual(point.x, 10)
        XCTAssertEqual(point.y, 20)
    }

    // MARK: screen → SendInput absolute

    func testAbsoluteSpansTheFullRange() {
        let first = WindowsPointerMapping.absolutePoint(
            screenX: 0, screenY: 0, virtualDesktop: hd)
        XCTAssertEqual(first.x, 0)
        XCTAssertEqual(first.y, 0)

        // 65535/(extent-1), not 65535/extent, or the last column is unreachable.
        let last = WindowsPointerMapping.absolutePoint(
            screenX: 1919, screenY: 1079, virtualDesktop: hd)
        XCTAssertEqual(last.x, 65535)
        XCTAssertEqual(last.y, 65535)
    }

    func testNegativeVirtualDesktopOrigin() {
        // A monitor left of the primary: SM_XVIRTUALSCREEN is negative;
        // treating it as zero is the "control only works on one screen" bug.
        let desktop = WindowsPointerMapping.ScreenRect(
            x: -1920, y: 0, width: 3840, height: 1080)

        let leftEdge = WindowsPointerMapping.absolutePoint(
            screenX: -1920, screenY: 0, virtualDesktop: desktop)
        XCTAssertEqual(leftEdge.x, 0, "the left monitor's edge is the START of the range")

        let rightEdge = WindowsPointerMapping.absolutePoint(
            screenX: 1919, screenY: 0, virtualDesktop: desktop)
        XCTAssertEqual(rightEdge.x, 65535)

        // The seam (screen x == 0, primary's left edge) lands just past the
        // midpoint since the range divides over `width - 1` columns —
        // 32768 is the plausible-looking wrong answer.
        let seam = WindowsPointerMapping.absolutePoint(
            screenX: 0, screenY: 0, virtualDesktop: desktop)
        XCTAssertEqual(seam.x, 32776)
    }

    func testOutsideTheVirtualDesktopClampsRatherThanWrapping() {
        let far = WindowsPointerMapping.absolutePoint(
            screenX: 99_999, screenY: -99_999, virtualDesktop: hd)
        XCTAssertEqual(far.x, 65535)
        XCTAssertEqual(far.y, 0)
    }

    func testOnePixelDesktopDoesNotDivideByZero() {
        let degenerate = WindowsPointerMapping.ScreenRect(x: 0, y: 0, width: 1, height: 1)
        let point = WindowsPointerMapping.absolutePoint(
            screenX: 0, screenY: 0, virtualDesktop: degenerate)
        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 0)
    }

    // MARK: the whole hop

    func testWindowOnASecondMonitorMapsEndToEnd() {
        let desktop = WindowsPointerMapping.ScreenRect(
            x: -1920, y: 0, width: 3840, height: 1080)
        let window = WindowsPointerMapping.ScreenRect(
            x: -1920, y: 0, width: 960, height: 540)

        let topLeft = WindowsPointerMapping.absolutePoint(
            normalizedX: 0, normalizedY: 0, in: window, virtualDesktop: desktop)
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0)

        let bottomRight = WindowsPointerMapping.absolutePoint(
            normalizedX: 1, normalizedY: 1, in: window, virtualDesktop: desktop)
        // Window's last column = screen x -961 = 959px into the 3840-wide
        // desktop (origin -1920): 959*65535/3839 = 16371. A mapping ignoring
        // the desktop origin would put this near 65535 instead.
        XCTAssertEqual(bottomRight.x, 16371)
        XCTAssertLessThan(bottomRight.x, 65535, "a 960-wide window is not the whole desktop")
    }

    // MARK: scroll

    func testWheelDeltaIsOneDetentPerLine() {
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(1), 120)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(-3), -360)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(0.5), 60)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(0), 0)
    }

    func testWheelDeltaSaturatesRatherThanWrapping() {
        // mouseData is a signed 16-bit field; must saturate, not wrap.
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(1e9), Int32(Int16.max))
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(-1e9), Int32(Int16.min))
    }

    func testWheelDeltaRejectsNonFinite() {
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(.nan), 0)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(.infinity), 0)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(-.infinity), 0)
    }
}
