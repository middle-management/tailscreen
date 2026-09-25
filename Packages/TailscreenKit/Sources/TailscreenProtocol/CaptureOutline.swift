import Foundation

/// The recording indicator: a border drawn around exactly the region being
/// captured, for the life of a share. Chosen over a tray icon, which only
/// answers "a share is running somewhere," not "this is what they can see" —
/// an outline answers the sharper question in the place the person is
/// already looking, and is the only on-screen sign the capture moved on a
/// mid-share source change.
///
/// Pure arithmetic on a BGRA buffer, so it lives here rather than beside a
/// window — the two hosts that draw it have different windowing, but "covers
/// the screen instead of edging it" is the same bug on both.
public enum CaptureOutline {
    /// Premultiplied BGRA, matching `AnnotationRasterizer` — the outline shares
    /// its surface, drawn underneath the strokes.
    public static let bytesPerPixel = AnnotationRasterizer.bytesPerPixel

    /// Border width in pixels — thin enough not to hide edge content, thick
    /// enough to read as deliberate on a high-DPI screen.
    public static let defaultThickness = 4

    /// The border colour: opaque and warm, the near-universal recording
    /// idiom, legible against both light and dark desktops.
    public static let defaultColor = Annotation.RGBA(r: 0.98, g: 0.35, b: 0.15, a: 1)

    /// The largest border that still leaves something inside it. Not a
    /// tidiness clamp: a thickness at or above half the smaller dimension
    /// fills the buffer completely, painting a solid rectangle over a small
    /// shared window for the whole share.
    public static func usableThickness(width: Int, height: Int, requested: Int) -> Int {
        guard width > 0, height > 0, requested > 0 else { return 0 }
        // `- 1` / 2 rather than / 2: at exactly half there is no interior left.
        let limit = (min(width, height) - 1) / 2
        return max(0, min(requested, limit))
    }

    /// Draw the border into `surface`, over whatever is already there. Does
    /// not clear: the caller composites the outline first, annotations over
    /// it, so an edge stroke stays visible. No room for a border draws nothing.
    public static func draw(
        into surface: AnnotationRasterizer.Surface,
        thickness: Int = defaultThickness,
        color: Annotation.RGBA = defaultColor
    ) {
        let width = surface.width
        let height = surface.height
        guard width > 0, height > 0, surface.stride >= width * bytesPerPixel else { return }
        let border = usableThickness(width: width, height: height, requested: thickness)
        guard border > 0 else { return }

        for row in 0..<height {
            let onHorizontalEdge = row < border || row >= height - border
            let rowBase = surface.bgra + row * surface.stride
            if onHorizontalEdge {
                // A full row of the top or bottom bar.
                for column in 0..<width { write(rowBase + column * bytesPerPixel, color) }
                continue
            }
            // Between the bars: only the left and right uprights; everything else untouched.
            for column in 0..<border {
                write(rowBase + column * bytesPerPixel, color)
                write(rowBase + (width - 1 - column) * bytesPerPixel, color)
            }
        }
    }

    /// Premultiplied BGRA, same convention as `AnnotationRasterizer.blend` — they write into one buffer.
    @inline(__always)
    private static func write(_ pixel: UnsafeMutablePointer<UInt8>, _ color: Annotation.RGBA) {
        let alpha = min(max(color.a, 0), 1)
        pixel[0] = channel(color.b * alpha)
        pixel[1] = channel(color.g * alpha)
        pixel[2] = channel(color.r * alpha)
        pixel[3] = channel(alpha)
    }

    @inline(__always)
    private static func channel(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }
}
