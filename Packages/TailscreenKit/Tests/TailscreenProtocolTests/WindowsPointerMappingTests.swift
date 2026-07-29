import XCTest

@testable import TailscreenProtocol

/// Tests for `WindowsPointerMapping` — the normalized-coordinate → `SendInput`
/// arithmetic behind remote control on Windows.
///
/// Every case here is a bug that is invisible on a single-monitor developer
/// machine and obvious to a user: a pointer confined to the primary display, a
/// last pixel column that cannot be clicked, a wrapped coordinate that throws
/// the cursor across the desk. None of it can be checked on the machine that
/// runs it, so it is checked here.
final class WindowsPointerMappingTests: XCTestCase {
    private let hd = WindowsPointerMapping.ScreenRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: normalized → screen

    func testCornersMapToTheRegionsCorners() {
        let topLeft = WindowsPointerMapping.screenPoint(normalizedX: 0, normalizedY: 0, in: hd)
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0)

        // The LAST addressable pixel, not the width — which is where the
        // scrollbar, the Close button and the screen edge all live.
        let bottomRight = WindowsPointerMapping.screenPoint(normalizedX: 1, normalizedY: 1, in: hd)
        XCTAssertEqual(bottomRight.x, 1919)
        XCTAssertEqual(bottomRight.y, 1079)
    }

    func testRegionOriginIsAdded() {
        // A window share: the region is somewhere on the desktop, and a
        // normalized point is relative to the WINDOW, not the screen.
        let window = WindowsPointerMapping.ScreenRect(x: 300, y: 200, width: 800, height: 600)
        let middle = WindowsPointerMapping.screenPoint(
            normalizedX: 0.5, normalizedY: 0.5, in: window)
        XCTAssertEqual(middle.x, 300 + 400)  // (800-1)*0.5 = 399.5, rounds to 400
        XCTAssertEqual(middle.y, 200 + 300)  // (600-1)*0.5 = 299.5, rounds to 300
    }

    func testOutOfRangeIsClampedNotExtrapolated() {
        // Wire-supplied. A viewer must not be able to place the pointer
        // outside the region its user can see.
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

        // 65535/(extent-1), not 65535/extent: with the latter the last column
        // lands at 65500 and is unreachable.
        let last = WindowsPointerMapping.absolutePoint(
            screenX: 1919, screenY: 1079, virtualDesktop: hd)
        XCTAssertEqual(last.x, 65535)
        XCTAssertEqual(last.y, 65535)
    }

    func testNegativeVirtualDesktopOrigin() {
        // A second monitor to the LEFT of the primary: SM_XVIRTUALSCREEN is
        // negative, and treating it as zero is the "remote control only works
        // on one screen" bug.
        let desktop = WindowsPointerMapping.ScreenRect(
            x: -1920, y: 0, width: 3840, height: 1080)

        let leftEdge = WindowsPointerMapping.absolutePoint(
            screenX: -1920, screenY: 0, virtualDesktop: desktop)
        XCTAssertEqual(leftEdge.x, 0, "the left monitor's edge is the START of the range")

        let rightEdge = WindowsPointerMapping.absolutePoint(
            screenX: 1919, screenY: 0, virtualDesktop: desktop)
        XCTAssertEqual(rightEdge.x, 65535)

        // The seam between the two monitors — screen x == 0, which is the
        // primary's left edge. Just PAST the midpoint, not at it: the range is
        // divided over `width - 1` addressable columns, so 1920/3839 exceeds
        // one half. 32768 is the plausible-looking wrong answer.
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
        // The case that combines every trap: a window share on a monitor left
        // of the primary. Its top-left must reach the far left of the absolute
        // range, and its bottom-right must not.
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
        // Both hops, spelled out, because reading either one alone gives a
        // wrong answer: the window's last column is screen x = -1920 + 959 =
        // -961, which is 959 pixels into a 3840-wide desktop whose origin is
        // -1920 — so 959 * 65535 / 3839 = 16371. Note it is well under half:
        // the window occupies the left quarter of the desktop, and a mapping
        // that ignored the desktop origin would put this near 65535 instead.
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
        // mouseData is a signed 16-bit field. A wire-supplied 1e9 lines must
        // saturate, not wrap around into a scroll the other way.
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(1e9), Int32(Int16.max))
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(-1e9), Int32(Int16.min))
    }

    func testWheelDeltaRejectsNonFinite() {
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(.nan), 0)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(.infinity), 0)
        XCTAssertEqual(WindowsPointerMapping.wheelDelta(-.infinity), 0)
    }
}
