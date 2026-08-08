import XCTest

@testable import TailscreenProtocol

/// Tests for `WindowsCaptureRegion` — recovering which monitor a WGC capture
/// item refers to, since the item itself does not say.
///
/// The case that matters most is the one that returns nothing: two monitors of
/// the same resolution. It is a common desk, it is genuinely unresolvable from
/// the item's size, and the wrong answer sends a viewer's clicks to a screen
/// they cannot see. So "declines when ambiguous" is the property under test,
/// not an edge case appended to it.
final class WindowsCaptureRegionTests: XCTestCase {
    private let primary = WindowsPointerMapping.ScreenRect(
        x: 0, y: 0, width: 1920, height: 1080)
    private let leftFourK = WindowsPointerMapping.ScreenRect(
        x: -3840, y: 0, width: 3840, height: 2160)

    func testUniqueResolutionResolves() {
        let result = WindowsCaptureRegion.resolve(
            itemWidth: 3840, itemHeight: 2160, monitors: [primary, leftFourK])
        guard case .success(let rect) = result else { return XCTFail("expected a match") }
        XCTAssertEqual(rect, leftFourK)
        XCTAssertEqual(rect.x, -3840, "the negative origin survives — it is the whole point")
    }

    func testSingleMonitorResolves() {
        let result = WindowsCaptureRegion.resolve(
            itemWidth: 1920, itemHeight: 1080, monitors: [primary])
        guard case .success(let rect) = result else { return XCTFail("expected a match") }
        XCTAssertEqual(rect, primary)
    }

    func testTwoIdenticalMonitorsDecline() {
        // The common dual-1080p desk. Both monitors match, and nothing in the
        // item says which — so this must NOT pick one.
        let second = WindowsPointerMapping.ScreenRect(
            x: 1920, y: 0, width: 1920, height: 1080)
        let result = WindowsCaptureRegion.resolve(
            itemWidth: 1920, itemHeight: 1080, monitors: [primary, second])
        XCTAssertEqual(result, .failure(.ambiguousDisplays(count: 2)))
    }

    func testThreeIdenticalMonitorsReportTheirCount() {
        let monitors = [
            primary,
            WindowsPointerMapping.ScreenRect(x: 1920, y: 0, width: 1920, height: 1080),
            WindowsPointerMapping.ScreenRect(x: 3840, y: 0, width: 1920, height: 1080)
        ]
        let result = WindowsCaptureRegion.resolve(
            itemWidth: 1920, itemHeight: 1080, monitors: monitors)
        XCTAssertEqual(result, .failure(.ambiguousDisplays(count: 3)))
    }

    func testAWindowSizedItemIsNotADisplay() {
        let result = WindowsCaptureRegion.resolve(
            itemWidth: 800, itemHeight: 600, monitors: [primary, leftFourK])
        XCTAssertEqual(result, .failure(.notADisplay))
    }

    func testAFullscreenWindowResolvesToItsMonitorAndThatIsFine() {
        // A fullscreen window's size equals its monitor's, so this reports a
        // display match. Not a defect: the rect is the same either way, so the
        // coordinate mapping is correct regardless of which it "really" was.
        let result = WindowsCaptureRegion.resolve(
            itemWidth: 1920, itemHeight: 1080, monitors: [primary, leftFourK])
        guard case .success(let rect) = result else { return XCTFail("expected a match") }
        XCTAssertEqual(rect, primary)
    }

    func testNoMonitorsIsUnknownGeometry() {
        XCTAssertEqual(
            WindowsCaptureRegion.resolve(itemWidth: 1920, itemHeight: 1080, monitors: []),
            .failure(.unknownGeometry))
    }

    func testZeroSizedItemIsUnknownGeometry() {
        // `WGC.CaptureItem.size` reports (0, 0) when the shim call fails, and
        // zero must not be matched against a monitor of any size.
        XCTAssertEqual(
            WindowsCaptureRegion.resolve(itemWidth: 0, itemHeight: 0, monitors: [primary]),
            .failure(.unknownGeometry))
        XCTAssertEqual(
            WindowsCaptureRegion.resolve(itemWidth: 1920, itemHeight: 0, monitors: [primary]),
            .failure(.unknownGeometry))
    }

    func testFailuresExplainThemselves() {
        // These strings reach the sharer's UI: "Request Control is missing"
        // with no reason is a support ticket.
        XCTAssertTrue(
            WindowsCaptureRegion.Failure.notADisplay.description.contains("window share"))
        XCTAssertTrue(
            WindowsCaptureRegion.Failure.ambiguousDisplays(count: 2).description.contains("2"))
    }
}
