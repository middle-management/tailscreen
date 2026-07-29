import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Draws annotations into a BGRA pixel buffer.
///
/// macOS renders them with Core Graphics and the GTK viewer with OpenGL, both
/// of which hand the hard part to a library. Windows has no equivalent that is
/// reachable from here: GDI+ is C++ and drags in the standard library that
/// already broke WASAPIKit, and Direct2D is a COM stack larger than the
/// feature. What the platform DOES offer for free is `UpdateLayeredWindow`,
/// which takes a premultiplied BGRA bitmap and composites it — so the missing
/// piece is not a drawing API, it is a rasterizer, and a rasterizer is
/// arithmetic.
///
/// Which means it belongs here, where Linux CI can check it, rather than in a
/// Windows shim where nothing could.
///
/// **Premultiplied alpha**, because that is what `UpdateLayeredWindow`
/// requires and getting it wrong produces a dark halo around every stroke
/// rather than an error.
public enum AnnotationRasterizer {
    /// Bytes per pixel in the output.
    public static let bytesPerPixel = 4

    /// The short-edge length `Annotation.width` is quoted against. A width of
    /// 3 means 3 pixels on a surface this tall, and proportionally more or
    /// less on any other.
    public static let referenceShortEdge: Double = 1000

    /// Clear `bgra` to fully transparent and draw `annotations` over it.
    ///
    /// - Parameters:
    ///   - annotations: in draw order — later ones cover earlier ones.
    ///   - width: buffer width in pixels.
    ///   - height: buffer height in pixels.
    ///   - stride: bytes per row; `width * 4` when tightly packed.
    ///   - bgra: destination, at least `stride * height` bytes.
    ///
    /// Stroke widths in `Annotation` are relative to the video's short edge
    /// (the same convention both existing renderers use), so they scale with
    /// the surface rather than becoming hairlines on a 4K display.
    public static func render(
        _ annotations: [Annotation],
        width: Int,
        height: Int,
        stride: Int,
        into bgra: UnsafeMutablePointer<UInt8>
    ) {
        guard width > 0, height > 0, stride >= width * bytesPerPixel else { return }
        for row in 0..<height {
            let base = bgra + row * stride
            base.update(repeating: 0, count: width * bytesPerPixel)
        }
        guard !annotations.isEmpty else { return }

        let shortEdge = Double(min(width, height))
        let aspect = Double(width) / Double(height)
        for annotation in annotations {
            let points = AnnotationGeometry.polyline(
                tool: annotation.tool,
                points: annotation.points,
                headLength: AnnotationGeometry.arrowHeadLength(strokeWidth: annotation.width)
                    / Double(height),
                clickRadius: AnnotationGeometry.clickOuterRadius(strokeWidth: annotation.width)
                    / Double(height),
                aspect: aspect)
            guard points.count >= 2 else { continue }

            // `Annotation.width` is in points relative to the video's short
            // edge, which needs a reference to mean anything in pixels:
            // `referenceShortEdge` is that reference, so the default 3-point
            // stroke is 3 px on a 1000-px-tall surface and scales with the
            // display instead of becoming a hairline on a 4K one. Floored at
            // one pixel, because a stroke nobody can see is not a stroke.
            let strokePixels = max(1, annotation.width * shortEdge / Self.referenceShortEdge)
            let halfWidth = strokePixels / 2
            for index in 0..<(points.count - 1) {
                drawSegment(
                    from: points[index], to: points[index + 1],
                    halfWidth: halfWidth, color: annotation.color,
                    width: width, height: height, stride: stride, bgra: bgra)
            }
        }
    }

    /// One round-capped segment, antialiased by coverage.
    ///
    /// Coverage is `halfWidth + 0.5 - distance` clamped to 0…1 — the standard
    /// signed-distance trick. Round caps come free from measuring distance to
    /// the SEGMENT rather than to the infinite line, which is also what makes
    /// a polyline's joints look continuous without any join handling.
    private static func drawSegment(
        from start: CGPoint,
        to end: CGPoint,
        halfWidth: Double,
        color: Annotation.RGBA,
        width: Int,
        height: Int,
        stride: Int,
        bgra: UnsafeMutablePointer<UInt8>
    ) {
        let x0 = Double(start.x) * Double(width)
        let y0 = Double(start.y) * Double(height)
        let x1 = Double(end.x) * Double(width)
        let y1 = Double(end.y) * Double(height)
        guard x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite else { return }

        // Only the pixels the segment can reach, clipped to the buffer. A
        // stroke dragged off-screen is normal, so this clips rather than
        // rejecting.
        let pad = halfWidth + 1
        let minX = max(0, Int((min(x0, x1) - pad).rounded(.down)))
        let maxX = min(width - 1, Int((max(x0, x1) + pad).rounded(.up)))
        let minY = max(0, Int((min(y0, y1) - pad).rounded(.down)))
        let maxY = min(height - 1, Int((max(y0, y1) + pad).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }

        let dx = x1 - x0
        let dy = y1 - y0
        let lengthSquared = dx * dx + dy * dy

        for py in minY...maxY {
            let row = bgra + py * stride
            for px in minX...maxX {
                // Pixel centre, not corner: a half-pixel bias is a visible
                // shift on a thin stroke.
                let cx = Double(px) + 0.5
                let cy = Double(py) + 0.5
                var t = 0.0
                if lengthSquared > 0 {
                    t = ((cx - x0) * dx + (cy - y0) * dy) / lengthSquared
                    t = min(max(t, 0), 1)
                }
                let nearestX = x0 + t * dx
                let nearestY = y0 + t * dy
                let distance =
                    ((cx - nearestX) * (cx - nearestX)
                    + (cy - nearestY) * (cy - nearestY)).squareRoot()
                let coverage = min(max(halfWidth + 0.5 - distance, 0), 1)
                guard coverage > 0 else { continue }
                blend(row + px * bytesPerPixel, color: color, coverage: coverage * color.a)
            }
        }
    }

    /// Source-over, premultiplied.
    private static func blend(
        _ pixel: UnsafeMutablePointer<UInt8>, color: Annotation.RGBA, coverage: Double
    ) {
        let alpha = min(max(coverage, 0), 1)
        let inverse = 1 - alpha
        // BGRA byte order, premultiplied: the colour channels carry alpha
        // already, which is what UpdateLayeredWindow composites directly.
        pixel[0] = channel(color.b * alpha + Double(pixel[0]) / 255 * inverse)
        pixel[1] = channel(color.g * alpha + Double(pixel[1]) / 255 * inverse)
        pixel[2] = channel(color.r * alpha + Double(pixel[2]) / 255 * inverse)
        pixel[3] = channel(alpha + Double(pixel[3]) / 255 * inverse)
    }

    private static func channel(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }
}
