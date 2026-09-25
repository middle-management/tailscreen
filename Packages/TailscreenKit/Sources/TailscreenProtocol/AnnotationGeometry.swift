import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The shared *shape* of an annotation: how an ``Annotation``'s stored points
/// become the outline every platform draws.
///
/// Shape tools store only what the user dragged (an anchor and the current
/// point); the outline is derived at render time. Both endpoints render each
/// other's relayed strokes, so the constants and barb math live here so an
/// arrow drawn on Linux matches one drawn on macOS.
///
/// Coordinate-space agnostic: callers pass whatever space they draw in
/// (normalized, pixel `CGRect`, …) with `headLength` already in those units,
/// and geometry comes back in the same units.
///
/// ``polyline(tool:points:headLength:clickRadius:aspect:)`` is the flattened
/// form a vertex-array renderer needs; a path-based renderer can use
/// ``arrowBarbs(from:to:headLength:)`` and the constants directly instead.
public enum AnnotationGeometry {
    // MARK: Shared constants

    /// Points used to approximate an oval/ring when flattening to a polyline.
    /// Only the polyline path uses this; a `CGPath` renderer draws a true arc.
    public static let ovalSegments = 48

    /// Half-angle of the arrowhead barbs, measured from the reversed shaft.
    /// `5π/6` matches the macOS overlay's `headAng` — barbs at ±150° from the
    /// shaft direction.
    public static let arrowHeadAngle = Double.pi * 5 / 6

    /// Arrowhead length for a stroke of `width`, same units as `width`.
    /// Mirrors the macOS overlay (`max(12, width * 4)`): a fixed size, not a
    /// fraction of the shaft, so short and long arrows have equally legible heads.
    public static func arrowHeadLength(strokeWidth: Double) -> Double {
        max(12.0, strokeWidth * 4)
    }

    /// Outer ring radius of the `click` bullseye for a stroke of `width`,
    /// matching the macOS `ClickMarker` (`max(14, width * 6)`).
    public static func clickOuterRadius(strokeWidth: Double) -> Double {
        max(14.0, strokeWidth * 6)
    }

    /// Filled centre-dot radius of the `click` bullseye, matching the macOS
    /// `ClickMarker` (`max(3, width * 1.2)`).
    public static func clickInnerRadius(strokeWidth: Double) -> Double {
        max(3.0, strokeWidth * 1.2)
    }

    /// Fallback arrowhead length in normalized units, for callers with no
    /// render size to convert with — about `arrowHeadLength(strokeWidth: 3)`
    /// over a 540-tall surface.
    public static let defaultNormalizedHeadLength = 0.025
    /// Fallback click-ring radius in normalized units, on the same basis.
    public static let defaultNormalizedClickRadius = 0.028

    // MARK: Arrow

    /// The two barb endpoints of an arrowhead at `to`, for a shaft running
    /// `from` → `to`. Works in whatever space the caller passes; `headLength`
    /// must be in those units. A zero-length shaft has no direction, so both
    /// barbs collapse onto the tip.
    public static func arrowBarbs(
        from: CGPoint, to: CGPoint, headLength: Double
    ) -> (left: CGPoint, right: CGPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard dx != 0 || dy != 0 else { return (to, to) }
        let angle = atan2(dy, dx)
        let left = CGPoint(
            x: to.x + cos(angle + arrowHeadAngle) * headLength,
            y: to.y + sin(angle + arrowHeadAngle) * headLength)
        let right = CGPoint(
            x: to.x + cos(angle - arrowHeadAngle) * headLength,
            y: to.y + sin(angle - arrowHeadAngle) * headLength)
        return (left, right)
    }

    // MARK: Polyline flattening (vertex-array renderers)

    /// Expand `points` for `tool` into a single renderable polyline.
    ///
    /// `pen` passes through. Shape tools use the first and last points as the
    /// drag anchor and current position, so a shape stays correct whether the
    /// capture layer replaced the moving point or appended to it. Degenerate
    /// input returns the raw points.
    ///
    /// - Parameters:
    ///   - headLength: arrowhead length in the same units as `points` — see
    ///     ``arrowHeadLength(strokeWidth:)``, divided by the render height.
    ///   - clickRadius: click-ring radius, likewise.
    ///   - aspect: the render surface's width÷height. Applied to the round
    ///     `click` marker only, so it stays a visual circle rather than
    ///     stretching on non-square video. Shapes the user dragged out keep the
    ///     proportions they were drawn with.
    public static func polyline(
        tool: AnnotationTool,
        points: [CGPoint],
        headLength: Double = defaultNormalizedHeadLength,
        clickRadius: Double = defaultNormalizedClickRadius,
        aspect: Double = 1
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
            guard first != last else { return [first, last] }
            let barbs = arrowBarbs(from: first, to: last, headLength: headLength)
            // One polyline: shaft → tip → barb → back to tip → other barb.
            return [first, last, barbs.left, last, barbs.right]
        case .rectangle:
            return [
                first,
                CGPoint(x: last.x, y: first.y),
                last,
                CGPoint(x: first.x, y: last.y),
                first
            ]
        case .oval:
            return oval(from: first, to: last)
        }
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
    /// in normalized *height* units, and the x-radius is divided by the surface
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
