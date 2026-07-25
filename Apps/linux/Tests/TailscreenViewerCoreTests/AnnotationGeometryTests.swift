import Foundation
import XCTest

@testable import TailscreenProtocol
@testable import TailscreenViewerCore

/// Pure-geometry coverage for the GTK viewer's annotation shape tools — the
/// half that's provable without a display (the GTK capture + GL draw are
/// compile-gated, like the rest of the viewer's UI layer).
final class AnnotationGeometryTests: XCTestCase {

    private let a = CGPoint(x: 0.2, y: 0.3)
    private let b = CGPoint(x: 0.8, y: 0.7)

    // MARK: pass-through + degenerate

    func testPenPassesPointsThrough() {
        let pts = [a, CGPoint(x: 0.5, y: 0.5), b]
        XCTAssertEqual(AnnotationGeometry.polyline(tool: .pen, points: pts), pts)
    }

    func testEmptyInputYieldsEmpty() {
        for tool in AnnotationTool.allCases {
            XCTAssertTrue(AnnotationGeometry.polyline(tool: tool, points: []).isEmpty)
        }
    }

    func testShapesUseFirstAndLastPointOnly() {
        // A shape dragged through intermediate points must look identical to the
        // same drag with only its endpoints — the capture layer is free to
        // append or replace while dragging.
        for tool in [AnnotationTool.line, .arrow, .rectangle, .oval] {
            let direct = AnnotationGeometry.polyline(tool: tool, points: [a, b])
            let viaMiddle = AnnotationGeometry.polyline(
                tool: tool, points: [a, CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6), b])
            XCTAssertEqual(direct, viaMiddle, "\(tool) should depend only on first+last")
        }
    }

    // MARK: line / rectangle

    func testLineIsTheTwoEndpoints() {
        XCTAssertEqual(AnnotationGeometry.polyline(tool: .line, points: [a, b]), [a, b])
    }

    func testRectangleIsAClosedFourCornerLoop() {
        let r = AnnotationGeometry.polyline(tool: .rectangle, points: [a, b])
        XCTAssertEqual(r.count, 5, "4 corners + closing point")
        XCTAssertEqual(r.first, r.last, "outline must close")
        // Every corner of the drag's bounding box appears exactly once (the
        // closing point repeats the origin).
        XCTAssertEqual(Set(r.map { "\($0.x),\($0.y)" }).count, 4)
        for p in r {
            XCTAssertTrue(p.x == a.x || p.x == b.x)
            XCTAssertTrue(p.y == a.y || p.y == b.y)
        }
    }

    func testRectangleHandlesInvertedDrag() {
        // Dragging up-left must produce the same box as dragging down-right.
        let forward = Set(
            AnnotationGeometry.polyline(tool: .rectangle, points: [a, b]).map { "\($0.x),\($0.y)" })
        let backward = Set(
            AnnotationGeometry.polyline(tool: .rectangle, points: [b, a]).map { "\($0.x),\($0.y)" })
        XCTAssertEqual(forward, backward)
    }

    // MARK: oval

    func testOvalIsClosedAndInscribedInTheDragBox() {
        let o = AnnotationGeometry.polyline(tool: .oval, points: [a, b])
        XCTAssertEqual(o.count, AnnotationGeometry.ovalSegments + 1)
        let first = try! XCTUnwrap(o.first)
        let last = try! XCTUnwrap(o.last)
        XCTAssertEqual(first.x, last.x, accuracy: 1e-9, "ellipse must close")
        XCTAssertEqual(first.y, last.y, accuracy: 1e-9)
        // Stays within the drag's bounding box (with float slack).
        for p in o {
            XCTAssertGreaterThanOrEqual(p.x, min(a.x, b.x) - 1e-9)
            XCTAssertLessThanOrEqual(p.x, max(a.x, b.x) + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, min(a.y, b.y) - 1e-9)
            XCTAssertLessThanOrEqual(p.y, max(a.y, b.y) + 1e-9)
        }
        // And actually spans it (touches both x extremes).
        XCTAssertEqual(o.map(\.x).min()!, min(a.x, b.x), accuracy: 1e-9)
        XCTAssertEqual(o.map(\.x).max()!, max(a.x, b.x), accuracy: 1e-9)
    }

    func testDegenerateOvalDoesNotCrash() {
        let o = AnnotationGeometry.polyline(tool: .oval, points: [a, a])
        XCTAssertEqual(o.count, AnnotationGeometry.ovalSegments + 1)
        for p in o {
            XCTAssertEqual(p.x, a.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, a.y, accuracy: 1e-9)
        }
    }

    // MARK: arrow

    func testArrowIsShaftPlusTwoBarbsAtTheTip() {
        let arrow = AnnotationGeometry.polyline(tool: .arrow, points: [a, b])
        // shaft(from,to) + barb + back to tip + barb
        XCTAssertEqual(arrow.count, 5)
        XCTAssertEqual(arrow[0], a, "starts at the anchor")
        XCTAssertEqual(arrow[1], b, "shaft ends at the tip")
        XCTAssertEqual(arrow[3], b, "returns to the tip between barbs")
        // Barbs sit behind the tip (closer to the anchor than the tip is).
        let shaftLength = hypot(b.x - a.x, b.y - a.y)
        for barb in [arrow[2], arrow[4]] {
            XCTAssertLessThan(hypot(barb.x - a.x, barb.y - a.y), shaftLength)
        }
        // …and symmetrically about the shaft: equal distance from the tip.
        XCTAssertEqual(
            hypot(arrow[2].x - b.x, arrow[2].y - b.y),
            hypot(arrow[4].x - b.x, arrow[4].y - b.y),
            accuracy: 1e-9)
    }

    func testZeroLengthArrowDegradesToTwoPoints() {
        XCTAssertEqual(AnnotationGeometry.polyline(tool: .arrow, points: [a, a]), [a, a])
    }

    // MARK: click

    func testClickIsAClosedRingAtTheTapPoint() {
        let ring = AnnotationGeometry.polyline(tool: .click, points: [a])
        XCTAssertEqual(ring.count, AnnotationGeometry.ovalSegments + 1)
        XCTAssertEqual(ring.first!.x, ring.last!.x, accuracy: 1e-9)
        // Square frame (aspect 1): a true circle in normalized space.
        for p in ring {
            XCTAssertEqual(
                hypot(p.x - a.x, p.y - a.y), AnnotationGeometry.clickRadius, accuracy: 1e-9)
        }
    }

    func testClickRingIsAspectCorrectedSoItRendersCircular() {
        // On 16:9 video the x-radius must shrink by the aspect, so the ring is
        // a VISUAL circle rather than a stretched ellipse.
        let aspect = 16.0 / 9.0
        let ring = AnnotationGeometry.polyline(tool: .click, points: [a], aspect: aspect)
        let xs = ring.map(\.x)
        let ys = ring.map(\.y)
        let rx = (xs.max()! - xs.min()!) / 2
        let ry = (ys.max()! - ys.min()!) / 2
        XCTAssertEqual(ry, AnnotationGeometry.clickRadius, accuracy: 1e-9)
        XCTAssertEqual(rx, AnnotationGeometry.clickRadius / aspect, accuracy: 1e-9)
        // Scaling x back up by the aspect recovers a circle — i.e. it is round
        // once the renderer applies the frame's aspect.
        for p in ring {
            XCTAssertEqual(
                hypot((p.x - a.x) * aspect, p.y - a.y),
                AnnotationGeometry.clickRadius, accuracy: 1e-9)
        }
    }

    // MARK: anchored classification

    func testOnlyPenIsFreehand() {
        XCTAssertFalse(AnnotationGeometry.isAnchored(.pen))
        for tool in [AnnotationTool.line, .arrow, .rectangle, .oval, .click] {
            XCTAssertTrue(AnnotationGeometry.isAnchored(tool), "\(tool) draws from an anchor")
        }
    }
}
