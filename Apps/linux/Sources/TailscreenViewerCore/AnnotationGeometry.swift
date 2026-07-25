import Foundation
import TailscreenProtocol

/// Turns an ``Annotation``'s stored points into the polyline the GL renderer
/// draws. Shape tools store only what the user dragged — an anchor and the
/// current point — so the outline (rectangle corners, ellipse arc, arrowhead)
/// is *derived* here rather than baked into the wire payload. That keeps the
/// wire format identical to the mac sharer's (which draws the same shapes from
/// the same two points) and keeps this expansion pure and unit-testable.
///
/// All coordinates are normalized `[0, 1]` in the video frame, origin top-left.
/// The renderer maps them through the aspect-fit/zoom transform, so a shape's
/// on-screen aspect follows the video — an "oval" here is an ellipse in
/// normalized space, matching how the mac overlay stores it.
public enum AnnotationGeometry {
    /// Points used to approximate an oval. 48 keeps the curve smooth at
    /// typical window sizes without bloating the vertex buffer.
    public static let ovalSegments = 48
    /// Arrowhead length as a fraction of the shaft length, and its half-angle.
    public static let arrowHeadFraction = 0.18
    public static let arrowHeadAngle = 0.42  // radians (~24°)
    /// Radius of the `click` marker ring.
    public static let clickRadius = 0.015

    /// Expand `points` for `tool` into a renderable polyline.
    ///
    /// `pen` passes through (it is already a freehand polyline). Shape tools use
    /// the FIRST and LAST points as the drag anchor and current position, so a
    /// shape stays correct whether the capture layer replaced the moving point
    /// or appended to it. Degenerate input (empty, or a shape with one point)
    /// returns the raw points rather than inventing geometry.
    ///
    /// `aspect` is the video's width÷height. Only the `click` marker uses it —
    /// its ring is a fixed *visual* circle, so its normalized x-radius must be
    /// divided by the aspect to avoid rendering as an ellipse on non-square
    /// video. Shapes the user dragged out are left alone: their proportions are
    /// what was drawn.
    public static func polyline(
        tool: AnnotationTool, points: [CGPoint], aspect: Double = 1
    ) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        switch tool {
        case .pen:
            return points
        case .click:
            return ring(center: first, radius: clickRadius, aspect: aspect)
        case .line:
            return [first, last]
        case .arrow:
            return arrow(from: first, to: last)
        case .rectangle:
            return [
                first,
                CGPoint(x: last.x, y: first.y),
                last,
                CGPoint(x: first.x, y: last.y),
                first,
            ]
        case .oval:
            return oval(from: first, to: last)
        }
    }

    /// Shaft plus a two-segment head at `to`, drawn as one polyline so the
    /// renderer needs no separate draw call: shaft → tip → barb → tip → barb.
    static func arrow(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return [from, to] }
        let headLength = length * arrowHeadFraction
        let angle = atan2(dy, dx)
        let left = angle + .pi - arrowHeadAngle
        let right = angle + .pi + arrowHeadAngle
        let barbLeft = CGPoint(
            x: to.x + cos(left) * headLength, y: to.y + sin(left) * headLength)
        let barbRight = CGPoint(
            x: to.x + cos(right) * headLength, y: to.y + sin(right) * headLength)
        return [from, to, barbLeft, to, barbRight]
    }

    /// Closed ellipse inscribed in the drag's bounding box.
    static func oval(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let cx = (from.x + to.x) / 2
        let cy = (from.y + to.y) / 2
        let rx = abs(to.x - from.x) / 2
        let ry = abs(to.y - from.y) / 2
        return (0...ovalSegments).map { i in
            let t = (Double(i) / Double(ovalSegments)) * 2 * .pi
            return CGPoint(x: cx + cos(t) * rx, y: cy + sin(t) * ry)
        }
    }

    /// Closed ring about `center` that renders as a visual circle: `radius` is
    /// in normalized *height* units, and the x-radius is divided by the frame
    /// aspect so wide video doesn't stretch it into an ellipse.
    static func ring(center: CGPoint, radius: Double, aspect: Double = 1) -> [CGPoint] {
        let rx = aspect > 0 ? radius / aspect : radius
        return (0...ovalSegments).map { i in
            let t = (Double(i) / Double(ovalSegments)) * 2 * .pi
            return CGPoint(x: center.x + cos(t) * rx, y: center.y + sin(t) * radius)
        }
    }

    /// True when the tool draws from a fixed anchor (drag updates one moving
    /// point) rather than accumulating a freehand trail. The capture layer uses
    /// this to decide whether to append or replace during a drag.
    public static func isAnchored(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .pen: return false
        case .line, .arrow, .rectangle, .oval, .click: return true
        }
    }
}
