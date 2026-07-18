import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Unit tests for the viewer's content zoom/pan geometry. Pure functions,
/// no AppKit windows — the CI-able core extracted from
/// `AspectFitHostView`'s gesture handling (pinch / ⌥-scroll / two-finger
/// pan / smart-magnify) per CLAUDE.md's extract-the-decision pattern.
final class ViewerZoomMathTests: XCTestCase {
    /// A left/right-letterboxed style fit rect: video centered inside a
    /// wider viewport, with a nonzero origin like `aspectFitRect()` returns.
    private let fit = CGRect(x: 40, y: 20, width: 640, height: 360)

    private func assertRectsEqual(
        _ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat = 1e-6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
    }

    /// Normalized video coordinate under a viewport point for a given
    /// video rect — the quantity anchor-preserving zoom must keep fixed.
    private func videoPoint(under point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    // MARK: - videoRect

    func testIdentityAtFit() {
        assertRectsEqual(ViewerZoomMath.videoRect(fit: fit, state: ViewerZoomState()), fit)
    }

    func testVideoRectScalesAboutFitCenter() {
        let rect = ViewerZoomMath.videoRect(fit: fit, state: ViewerZoomState(scale: 2, offset: .zero))
        XCTAssertEqual(rect.midX, fit.midX, accuracy: 1e-6)
        XCTAssertEqual(rect.midY, fit.midY, accuracy: 1e-6)
        XCTAssertEqual(rect.width, fit.width * 2, accuracy: 1e-6)
        XCTAssertEqual(rect.height, fit.height * 2, accuracy: 1e-6)
    }

    func testVideoRectAlwaysCoversFit() {
        // Sweep scales and deliberately excessive offsets: the zoomed rect
        // must never expose a gap between its edge and the fit rect's edge.
        for scale in [1.0, 1.5, 2.0, 4.0, 8.0] {
            for dx in [-10_000.0, -50.0, 0.0, 50.0, 10_000.0] {
                for dy in [-10_000.0, 0.0, 10_000.0] {
                    let state = ViewerZoomState(scale: CGFloat(scale), offset: CGPoint(x: dx, y: dy))
                    let rect = ViewerZoomMath.videoRect(fit: fit, state: state)
                    XCTAssertLessThanOrEqual(rect.minX, fit.minX + 1e-6)
                    XCTAssertLessThanOrEqual(rect.minY, fit.minY + 1e-6)
                    XCTAssertGreaterThanOrEqual(rect.maxX, fit.maxX - 1e-6)
                    XCTAssertGreaterThanOrEqual(rect.maxY, fit.maxY - 1e-6)
                }
            }
        }
    }

    func testVideoRectReclampsStaleOffsetAfterFitShrinks() {
        // A window resize shrank the fit rect: an offset that was legal
        // against the old fit is re-clamped so no gap opens.
        let state = ViewerZoomState(scale: 2, offset: CGPoint(x: 320, y: 180))
        let smaller = CGRect(x: 0, y: 0, width: 320, height: 180)
        let rect = ViewerZoomMath.videoRect(fit: smaller, state: state)
        XCTAssertLessThanOrEqual(rect.minX, smaller.minX + 1e-6)
        XCTAssertLessThanOrEqual(rect.minY, smaller.minY + 1e-6)
        XCTAssertGreaterThanOrEqual(rect.maxX, smaller.maxX - 1e-6)
        XCTAssertGreaterThanOrEqual(rect.maxY, smaller.maxY - 1e-6)
    }

    func testVideoRectDegenerateFitPassesThrough() {
        let empty = CGRect(x: 5, y: 5, width: 0, height: 0)
        XCTAssertEqual(
            ViewerZoomMath.videoRect(fit: empty, state: ViewerZoomState(scale: 4, offset: .zero)),
            empty)
    }

    // MARK: - zoomed

    func testZoomAnchorInvariance() {
        let anchor = CGPoint(x: 200, y: 100)
        let before = ViewerZoomState(scale: 2, offset: CGPoint(x: 30, y: -14))
        let after = ViewerZoomMath.zoomed(state: before, by: 1.5, anchor: anchor, fit: fit)
        let pointBefore = videoPoint(under: anchor, in: ViewerZoomMath.videoRect(fit: fit, state: before))
        let pointAfter = videoPoint(under: anchor, in: ViewerZoomMath.videoRect(fit: fit, state: after))
        XCTAssertEqual(after.scale, 3, accuracy: 1e-9)
        XCTAssertEqual(pointBefore.x, pointAfter.x, accuracy: 1e-6)
        XCTAssertEqual(pointBefore.y, pointAfter.y, accuracy: 1e-6)
    }

    func testZoomAnchorInvarianceInTallFit() {
        // Top/bottom-letterbox shape (portrait video in a landscape window).
        let tall = CGRect(x: 100, y: 0, width: 300, height: 500)
        let anchor = CGPoint(x: 150, y: 400)
        let after = ViewerZoomMath.zoomed(state: ViewerZoomState(), by: 2, anchor: anchor, fit: tall)
        let pointBefore = videoPoint(under: anchor, in: tall)
        let pointAfter = videoPoint(under: anchor, in: ViewerZoomMath.videoRect(fit: tall, state: after))
        XCTAssertEqual(pointBefore.x, pointAfter.x, accuracy: 1e-6)
        XCTAssertEqual(pointBefore.y, pointAfter.y, accuracy: 1e-6)
    }

    func testZoomInClampsAtMaxScale() {
        let state = ViewerZoomState(scale: 6, offset: .zero)
        let center = CGPoint(x: fit.midX, y: fit.midY)
        let zoomed = ViewerZoomMath.zoomed(state: state, by: 4, anchor: center, fit: fit)
        XCTAssertEqual(zoomed.scale, ViewerZoomMath.maxScale, accuracy: 1e-9)
    }

    func testZoomInClampsAtCallerMaxScale() {
        // Gesture call sites pass `effectiveMaxScale` — the parameterized
        // ceiling must win over the static one.
        let center = CGPoint(x: fit.midX, y: fit.midY)
        let zoomed = ViewerZoomMath.zoomed(
            state: ViewerZoomState(), by: 8, anchor: center, fit: fit, maxScale: 3)
        XCTAssertEqual(zoomed.scale, 3, accuracy: 1e-9)
    }

    func testZoomAfterFitShrinkKeepsAnchorStable() {
        // A window resize between gestures left `offset` legal only for
        // the old, larger fit. The displayed rect re-clamps it — and the
        // next zoom must anchor against that displayed rect, not the
        // stale offset, or the first gesture jumps discontinuously.
        let stale = ViewerZoomState(scale: 2, offset: CGPoint(x: 320, y: 180))
        let shrunken = CGRect(x: 0, y: 0, width: 320, height: 180)
        let displayed = ViewerZoomMath.videoRect(fit: shrunken, state: stale)
        let anchor = CGPoint(x: 80, y: 45)
        let after = ViewerZoomMath.zoomed(state: stale, by: 1.5, anchor: anchor, fit: shrunken)
        let pointBefore = videoPoint(under: anchor, in: displayed)
        let pointAfter = videoPoint(
            under: anchor, in: ViewerZoomMath.videoRect(fit: shrunken, state: after))
        XCTAssertEqual(pointBefore.x, pointAfter.x, accuracy: 1e-6)
        XCTAssertEqual(pointBefore.y, pointAfter.y, accuracy: 1e-6)
    }

    func testZoomOutClampsAtFitAndRecenters() {
        let state = ViewerZoomState(scale: 1.5, offset: CGPoint(x: 80, y: 40))
        let zoomed = ViewerZoomMath.zoomed(state: state, by: 0.1, anchor: CGPoint(x: 100, y: 50), fit: fit)
        XCTAssertEqual(zoomed.scale, ViewerZoomMath.minScale, accuracy: 1e-9)
        XCTAssertEqual(zoomed.offset.x, 0, accuracy: 1e-9)
        XCTAssertEqual(zoomed.offset.y, 0, accuracy: 1e-9)
    }

    func testZoomKeepsOffsetWithinPanBounds() {
        // Anchoring at a corner drives the offset toward the clamp; the
        // result must still satisfy the pan bounds for the new scale.
        let corner = CGPoint(x: fit.minX, y: fit.minY)
        var state = ViewerZoomState()
        for _ in 0..<20 {
            state = ViewerZoomMath.zoomed(state: state, by: 1.4, anchor: corner, fit: fit)
            let maxX = (state.scale - 1) * fit.width / 2
            let maxY = (state.scale - 1) * fit.height / 2
            XCTAssertLessThanOrEqual(abs(state.offset.x), maxX + 1e-6)
            XCTAssertLessThanOrEqual(abs(state.offset.y), maxY + 1e-6)
        }
        XCTAssertEqual(state.scale, ViewerZoomMath.maxScale, accuracy: 1e-9)
    }

    func testZoomRejectsNonPositiveDelta() {
        let state = ViewerZoomState(scale: 2, offset: CGPoint(x: 10, y: 10))
        XCTAssertEqual(ViewerZoomMath.zoomed(state: state, by: 0, anchor: .zero, fit: fit), state)
        XCTAssertEqual(ViewerZoomMath.zoomed(state: state, by: -1, anchor: .zero, fit: fit), state)
    }

    func testZoomDegenerateFitPassesThrough() {
        let state = ViewerZoomState(scale: 2, offset: CGPoint(x: 10, y: 10))
        let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(ViewerZoomMath.zoomed(state: state, by: 2, anchor: .zero, fit: empty), state)
    }

    // MARK: - panned

    func testPanMovesContent() {
        let state = ViewerZoomState(scale: 2, offset: .zero)
        let panned = ViewerZoomMath.panned(state: state, by: CGSize(width: 25, height: -10), fit: fit)
        XCTAssertEqual(panned.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(panned.offset.x, 25, accuracy: 1e-9)
        XCTAssertEqual(panned.offset.y, -10, accuracy: 1e-9)
    }

    func testPanClampsAtAllFourEdges() {
        let state = ViewerZoomState(scale: 2, offset: .zero)
        let maxX = (2.0 - 1.0) * fit.width / 2
        let maxY = (2.0 - 1.0) * fit.height / 2
        let right = ViewerZoomMath.panned(state: state, by: CGSize(width: 10_000, height: 0), fit: fit)
        XCTAssertEqual(right.offset.x, maxX, accuracy: 1e-9)
        let left = ViewerZoomMath.panned(state: state, by: CGSize(width: -10_000, height: 0), fit: fit)
        XCTAssertEqual(left.offset.x, -maxX, accuracy: 1e-9)
        let up = ViewerZoomMath.panned(state: state, by: CGSize(width: 0, height: 10_000), fit: fit)
        XCTAssertEqual(up.offset.y, maxY, accuracy: 1e-9)
        let down = ViewerZoomMath.panned(state: state, by: CGSize(width: 0, height: -10_000), fit: fit)
        XCTAssertEqual(down.offset.y, -maxY, accuracy: 1e-9)
    }

    func testPanAtFitStaysPut() {
        let panned = ViewerZoomMath.panned(
            state: ViewerZoomState(), by: CGSize(width: 50, height: 50), fit: fit)
        XCTAssertEqual(panned, ViewerZoomState())
    }

    // MARK: - smartMagnifyToggled

    func testSmartMagnifyZoomsToDoubleAtAnchor() {
        let anchor = CGPoint(x: 500, y: 300)
        let state = ViewerZoomMath.smartMagnifyToggled(
            state: ViewerZoomState(), anchor: anchor, fit: fit)
        XCTAssertEqual(state.scale, ViewerZoomMath.smartMagnifyScale, accuracy: 1e-9)
        let pointBefore = videoPoint(under: anchor, in: fit)
        let pointAfter = videoPoint(under: anchor, in: ViewerZoomMath.videoRect(fit: fit, state: state))
        XCTAssertEqual(pointBefore.x, pointAfter.x, accuracy: 1e-6)
        XCTAssertEqual(pointBefore.y, pointAfter.y, accuracy: 1e-6)
    }

    func testSmartMagnifyResetsWhenZoomed() {
        let state = ViewerZoomState(scale: 3, offset: CGPoint(x: 12, y: 34))
        XCTAssertEqual(
            ViewerZoomMath.smartMagnifyToggled(state: state, anchor: CGPoint(x: 100, y: 100), fit: fit),
            ViewerZoomState())
    }

    func testSmartMagnifyRespectsCallerMaxScale() {
        // Below-2× texture cap: the double-tap target clamps to it.
        let state = ViewerZoomMath.smartMagnifyToggled(
            state: ViewerZoomState(), anchor: CGPoint(x: fit.midX, y: fit.midY), fit: fit,
            maxScale: 1.5)
        XCTAssertEqual(state.scale, 1.5, accuracy: 1e-9)
    }

    // MARK: - effectiveMaxScale

    func testEffectiveMaxScaleCapsLargeContent() {
        // A 3000-pt fit on a 2× display would hit 48k px at 8× — well past
        // Core Animation's texture limit. The cap is exactly the scale
        // that keeps the longer axis at `safeMaxContentPixels`.
        let large = CGRect(x: 0, y: 0, width: 3000, height: 1800)
        let cap = ViewerZoomMath.effectiveMaxScale(fit: large, backingScale: 2)
        XCTAssertEqual(cap, ViewerZoomMath.safeMaxContentPixels / (3000 * 2), accuracy: 1e-9)
        XCTAssertLessThan(cap, ViewerZoomMath.maxScale)
        XCTAssertGreaterThanOrEqual(cap, ViewerZoomMath.minScale)
    }

    func testEffectiveMaxScaleNoOpForSmallContent() {
        // 640 pt × 2× × 8 = 10 240 px — comfortably under the limit, so
        // the static ceiling stands.
        XCTAssertEqual(
            ViewerZoomMath.effectiveMaxScale(fit: fit, backingScale: 2),
            ViewerZoomMath.maxScale, accuracy: 1e-9)
    }

    func testEffectiveMaxScaleFloorsAtMinScale() {
        // A pathologically huge fit can't push the cap below fit itself.
        let huge = CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
        XCTAssertEqual(
            ViewerZoomMath.effectiveMaxScale(fit: huge, backingScale: 2),
            ViewerZoomMath.minScale, accuracy: 1e-9)
    }

    func testEffectiveMaxScaleDegenerateFitPassesThrough() {
        XCTAssertEqual(
            ViewerZoomMath.effectiveMaxScale(fit: .zero, backingScale: 2),
            ViewerZoomMath.maxScale, accuracy: 1e-9)
    }

    // MARK: - isZoomedIn

    func testIsZoomedIn() {
        XCTAssertFalse(ViewerZoomState().isZoomedIn)
        XCTAssertFalse(ViewerZoomState(scale: ViewerZoomMath.minScale, offset: .zero).isZoomedIn)
        XCTAssertTrue(ViewerZoomState(scale: 1.01, offset: .zero).isZoomedIn)
        XCTAssertTrue(ViewerZoomState(scale: ViewerZoomMath.maxScale, offset: .zero).isZoomedIn)
    }
}
