import XCTest

@testable import TailscreenProtocol

/// Tests for `WindowsCaptureRegion` — recovering which monitor a WGC capture
/// item refers to, since the item itself does not say. The key property:
/// two monitors of the same resolution are genuinely unresolvable from size
/// alone, so it must decline rather than guess (sending clicks to the wrong
/// screen).
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
        // Fullscreen window size == monitor size, reports as a display match;
        // the rect is identical either way so this is fine.
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
        // `WGC.CaptureItem.size` reports (0, 0) on shim failure; must not
        // match any monitor size.
        XCTAssertEqual(
            WindowsCaptureRegion.resolve(itemWidth: 0, itemHeight: 0, monitors: [primary]),
            .failure(.unknownGeometry))
        XCTAssertEqual(
            WindowsCaptureRegion.resolve(itemWidth: 1920, itemHeight: 0, monitors: [primary]),
            .failure(.unknownGeometry))
    }

    func testFailuresExplainThemselves() {
        // Strings reach the sharer's UI, so they must state a reason.
        XCTAssertTrue(
            WindowsCaptureRegion.Failure.notADisplay.description.contains("window share"))
        XCTAssertTrue(
            WindowsCaptureRegion.Failure.ambiguousDisplays(count: 2).description.contains("2"))
    }
}
