import Foundation
import XCTest

@testable import TailscreenProtocol

/// Shared derivation from a stroke's anchor+current points to the drawn
/// outline. Portable so macOS and the Linux/GTK viewer render relayed
/// strokes identically.
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
        // Capture is free to append/replace intermediate points while dragging.
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
        XCTAssertEqual(Set(r.map { "\($0.x),\($0.y)" }).count, 4)  // 4 distinct corners
        for p in r {
            XCTAssertTrue(p.x == a.x || p.x == b.x)
            XCTAssertTrue(p.y == a.y || p.y == b.y)
        }
    }

    func testRectangleHandlesInvertedDrag() {
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
        for p in o {
            XCTAssertGreaterThanOrEqual(p.x, min(a.x, b.x) - 1e-9)
            XCTAssertLessThanOrEqual(p.x, max(a.x, b.x) + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, min(a.y, b.y) - 1e-9)
            XCTAssertLessThanOrEqual(p.y, max(a.y, b.y) + 1e-9)
        }
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
        let arrow = AnnotationGeometry.polyline(tool: .arrow, points: [a, b], headLength: 0.05)
        // shaft(from,to) + barb + back to tip + barb
        XCTAssertEqual(arrow.count, 5)
        XCTAssertEqual(arrow[0], a, "starts at the anchor")
        XCTAssertEqual(arrow[1], b, "shaft ends at the tip")
        XCTAssertEqual(arrow[3], b, "returns to the tip between barbs")
        let shaftLength = hypot(b.x - a.x, b.y - a.y)
        for barb in [arrow[2], arrow[4]] {
            XCTAssertLessThan(hypot(barb.x - a.x, barb.y - a.y), shaftLength)  // barbs sit behind the tip
        }
        XCTAssertEqual(
            hypot(arrow[2].x - b.x, arrow[2].y - b.y),
            hypot(arrow[4].x - b.x, arrow[4].y - b.y),
            accuracy: 1e-9)
    }

    func testZeroLengthArrowDegradesToTwoPoints() {
        XCTAssertEqual(AnnotationGeometry.polyline(tool: .arrow, points: [a, a]), [a, a])
    }

    /// Head length is fixed, not proportional to the shaft (macOS model) —
    /// keeps long and short arrows equally legible.
    func testArrowHeadSizeIsIndependentOfShaftLength() {
        let short = CGPoint(x: 0.3, y: 0.3)
        let long = CGPoint(x: 0.9, y: 0.9)
        let headLength = 0.04
        func barbDistance(to tip: CGPoint) -> Double {
            let arrow = AnnotationGeometry.polyline(
                tool: .arrow, points: [a, tip], headLength: headLength)
            return hypot(arrow[2].x - tip.x, arrow[2].y - tip.y)
        }
        XCTAssertEqual(barbDistance(to: short), headLength, accuracy: 1e-9)
        XCTAssertEqual(barbDistance(to: long), headLength, accuracy: 1e-9)
    }

    /// Must match the macOS overlay's formula — both ends render the same relayed `.arrow`.
    func testArrowBarbsMatchTheMacOverlayFormula() {
        let from = CGPoint(x: 100, y: 100)
        let to = CGPoint(x: 200, y: 180)  // pixel space, as the mac uses
        let headLength = AnnotationGeometry.arrowHeadLength(strokeWidth: 3)
        XCTAssertEqual(headLength, 12.0, accuracy: 1e-9, "max(12, 3*4) == 12")
        let barbs = AnnotationGeometry.arrowBarbs(from: from, to: to, headLength: headLength)
        // Reference: the macOS AnnotationCanvasView computation, inlined.
        let ang = atan2(to.y - from.y, to.x - from.x)
        let headAng = Double.pi * 5 / 6
        let expectedLeft = CGPoint(
            x: to.x + cos(ang + headAng) * headLength,
            y: to.y + sin(ang + headAng) * headLength)
        let expectedRight = CGPoint(
            x: to.x + cos(ang - headAng) * headLength,
            y: to.y + sin(ang - headAng) * headLength)
        XCTAssertEqual(barbs.left.x, expectedLeft.x, accuracy: 1e-9)
        XCTAssertEqual(barbs.left.y, expectedLeft.y, accuracy: 1e-9)
        XCTAssertEqual(barbs.right.x, expectedRight.x, accuracy: 1e-9)
        XCTAssertEqual(barbs.right.y, expectedRight.y, accuracy: 1e-9)
    }

    func testClickMarkerRadiiMatchTheMacFormula() {
        XCTAssertEqual(AnnotationGeometry.clickOuterRadius(strokeWidth: 3), 18, accuracy: 1e-9)
        XCTAssertEqual(AnnotationGeometry.clickOuterRadius(strokeWidth: 1), 14, accuracy: 1e-9)
        XCTAssertEqual(AnnotationGeometry.clickInnerRadius(strokeWidth: 10), 12, accuracy: 1e-9)
        XCTAssertEqual(AnnotationGeometry.clickInnerRadius(strokeWidth: 1), 3, accuracy: 1e-9)
    }

    // MARK: click

    func testClickIsAClosedRingAtTheTapPoint() {
        let radius = 0.03
        let ring = AnnotationGeometry.polyline(tool: .click, points: [a], clickRadius: radius)
        XCTAssertEqual(ring.count, AnnotationGeometry.ovalSegments + 1)
        XCTAssertEqual(ring.first!.x, ring.last!.x, accuracy: 1e-9)
        for p in ring {
            XCTAssertEqual(hypot(p.x - a.x, p.y - a.y), radius, accuracy: 1e-9)
        }
    }

    func testClickRingIsAspectCorrectedSoItRendersCircular() {
        // x-radius shrinks by the aspect so a 16:9 frame renders a visual circle, not an ellipse.
        let aspect = 16.0 / 9.0
        let radius = 0.03
        let ring = AnnotationGeometry.polyline(
            tool: .click, points: [a], clickRadius: radius, aspect: aspect)
        let xs = ring.map(\.x)
        let ys = ring.map(\.y)
        let rx = (xs.max()! - xs.min()!) / 2
        let ry = (ys.max()! - ys.min()!) / 2
        XCTAssertEqual(ry, radius, accuracy: 1e-9)
        XCTAssertEqual(rx, radius / aspect, accuracy: 1e-9)
        for p in ring {
            XCTAssertEqual(hypot((p.x - a.x) * aspect, p.y - a.y), radius, accuracy: 1e-9)
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
