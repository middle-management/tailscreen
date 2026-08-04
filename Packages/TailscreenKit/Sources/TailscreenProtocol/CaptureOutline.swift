import Foundation

/// The recording indicator: a border drawn around exactly the region being
/// captured, for the life of a share.
///
/// **Why this rather than a tray icon.** Working out what would actually go on
/// a tray killed the tray plan — everything on the candidate list was either
/// already reachable from the window, blocked on a capability, or better as a
/// notification. What was left was a status indicator, and a 16×16 glyph in a
/// corner nobody is looking at is a poor one. It also answers the weaker
/// question: "a share is running somewhere" rather than "**this** is what they
/// can see."
///
/// An outline answers the sharper one, in the place the person is already
/// looking. On a mid-share source change it is also the only thing on screen
/// that says the capture moved.
///
/// Pure arithmetic on a BGRA buffer, so it lives here rather than beside a
/// window: the two hosts that draw it have completely different windowing, and
/// the part that can be silently wrong — covering the screen instead of edging
/// it — is the same on both.
public enum CaptureOutline {
    /// Premultiplied BGRA, matching `AnnotationRasterizer` — the outline shares
    /// its surface, drawn underneath the strokes.
    public static let bytesPerPixel = AnnotationRasterizer.bytesPerPixel

    /// Border width in pixels.
    ///
    /// Thin enough not to hide content at the edges of what is being shared,
    /// thick enough to read as deliberate rather than as a rendering artifact
    /// on a high-DPI screen.
    public static let defaultThickness = 4

    /// The border colour. Opaque and warm, the near-universal recording idiom;
    /// it has to be legible against both a light and a dark desktop, which
    /// rules out anything low-contrast.
    public static let defaultColor = Annotation.RGBA(r: 0.98, g: 0.35, b: 0.15, a: 1)

    /// The largest border that still leaves something inside it.
    ///
    /// **Not a tidiness clamp.** The surface is the size of the captured
    /// region, and a thickness at or above half its smaller dimension fills the
    /// buffer completely — so a share of a small window would paint a solid
    /// rectangle over it, on the sharer's own screen, for the whole share. The
    /// outline exists to say where the boundary is; one with no interior says
    /// the opposite.
    public static func usableThickness(width: Int, height: Int, requested: Int) -> Int {
        guard width > 0, height > 0, requested > 0 else { return 0 }
        // `- 1` / 2 rather than / 2: at exactly half there is no interior left.
        let limit = (min(width, height) - 1) / 2
        return max(0, min(requested, limit))
    }

    /// Draw the border into `surface`, over whatever is already there.
    ///
    /// Does **not** clear: the caller composites the outline first and the
    /// annotations over it, so a stroke drawn near the edge stays visible
    /// rather than being framed out.
    ///
    /// A geometry with no room for a border draws nothing at all, which is the
    /// honest answer — better an absent indicator than a covered window.
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
            // Between the bars: only the left and right uprights. Everything
            // between them is left EXACTLY as it was, which is the whole
            // contract — this runs over the sharer's own screen.
            for column in 0..<border {
                write(rowBase + column * bytesPerPixel, color)
                write(rowBase + (width - 1 - column) * bytesPerPixel, color)
            }
        }
    }

    /// Premultiplied BGRA, same convention and byte order as
    /// `AnnotationRasterizer.blend` — the two write into one buffer, and a
    /// disagreement here shows up as an outline in the wrong colour rather
    /// than as an error.
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
