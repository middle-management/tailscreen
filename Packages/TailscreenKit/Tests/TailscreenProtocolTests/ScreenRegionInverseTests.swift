import XCTest

@testable import TailscreenProtocol

/// `ScreenRegion.normalizedPoint` must be the exact inverse of `point`, which
/// every other participant uses in the other direction — a mismatch is a
/// stroke landing a pixel off, agreeing with nothing.
final class ScreenRegionInverseTests: XCTestCase {
    /// A monitor left of the primary, so the origin is negative — the case that
    /// makes "just divide by the width" wrong.
    private let region = ScreenRegion(x: -1920, y: -200, width: 1920, height: 1080)

    /// Round-tripped exactly, not approximately: an earlier draft's 0.001
    /// tolerance was wider than dividing by `width` instead of `width - 1`
    /// would produce, so it passed against the defect. Sized so every sampled
    /// fraction lands on a whole pixel, leaving nothing for a tolerance to hide.
    func testItIsTheInverseOfPoint() {
        let exact = ScreenRegion(x: -1920, y: -200, width: 1025, height: 513)
        for nx in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for ny in [0.0, 0.5, 1.0] {
                let pixel = exact.point(normalizedX: nx, normalizedY: ny)
                let back = exact.normalizedPoint(screenX: pixel.x, screenY: pixel.y)
                XCTAssertEqual(back.x, nx, "x round trip at \(nx)")
                XCTAssertEqual(back.y, ny, "y round trip at \(ny)")
            }
        }
    }

    /// The last addressable column (`width - 1`) must read as 1.0, or the
    /// screen edge (scrollbars, close button) is permanently unreachable.
    func testTheLastPixelIsExactlyOne() {
        let corner = region.normalizedPoint(
            screenX: region.x + region.width - 1, screenY: region.y + region.height - 1)
        XCTAssertEqual(corner.x, 1.0)
        XCTAssertEqual(corner.y, 1.0)

        let origin = region.normalizedPoint(screenX: region.x, screenY: region.y)
        XCTAssertEqual(origin.x, 0.0)
        XCTAssertEqual(origin.y, 0.0)
    }

    /// A drag off the surface keeps delivering negative points; they must pin
    /// to the near edge, not the far edge a `LOWORD` read of Win32's signed
    /// 16-bit pair would send them to.
    func testOffTheEdgeClampsToTheNearEdgeNotTheFarOne() {
        let left = region.normalizedPoint(screenX: region.x - 300, screenY: region.y + 10)
        XCTAssertEqual(left.x, 0.0)

        let right = region.normalizedPoint(
            screenX: region.x + region.width + 4096, screenY: region.y + 10)
        XCTAssertEqual(right.x, 1.0)

        let above = region.normalizedPoint(screenX: region.x + 10, screenY: region.y - 5000)
        XCTAssertEqual(above.y, 0.0)
    }

    func testDegenerateRegionDoesNotDivideByZero() {
        let thin = ScreenRegion(x: 0, y: 0, width: 1, height: 0)
        let point = thin.normalizedPoint(screenX: 7, screenY: 7)
        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 0)
    }
}
