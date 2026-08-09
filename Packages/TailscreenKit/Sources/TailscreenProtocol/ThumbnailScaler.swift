import Foundation

/// Downscale a captured BGRA frame to a small RGBA thumbnail — the sharer's
/// own "this is what they can see" preview.
///
/// **Why RGBA out when everything else here is BGRA.** The two GUI hubs display
/// it through `SwiftCrossUI.Image`, whose in-memory initializer takes
/// `ImageFormats.Image<RGBA>` — packed R,G,B,A. Capture APIs hand back BGRA. So
/// a channel swap has to happen somewhere, and doing it here means it happens
/// once, in the same pass as the scale, in a tier Linux CI tests. Getting it
/// wrong does not fail: the preview renders with red and blue exchanged, which
/// on a screenshot of a desktop looks like a colour-management problem rather
/// than a bug.
///
/// **Why box-averaging rather than nearest.** A thumbnail of a screen is mostly
/// text. Point-sampling a 4 K desktop down to 160 px keeps one pixel in 24 and
/// turns text into noise that reads as a broken image; averaging the block
/// turns it into grey, which reads as small text. It costs one pass over the
/// source either way.
public enum ThumbnailScaler {
    /// Bytes per pixel, both directions. Named because `4` appears in every
    /// index computation below and a bare literal there is where an off-by-one
    /// hides.
    public static let bytesPerPixel = 4

    /// The result: packed RGBA at the scaled size.
    public struct Thumbnail: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// `width * height * 4` bytes, R,G,B,A per pixel, alpha always opaque.
        public let rgba: [UInt8]

        public init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width
            self.height = height
            self.rgba = rgba
        }
    }

    /// The longest edge a preview is scaled to fit within.
    ///
    /// Small on purpose: this is a thumbnail in a card, it is produced
    /// repeatedly for the life of a share, and every pixel is one the capture
    /// thread pays for. 360 rather than 240 because the share card now shows
    /// it at up to that size (`ShareCard`'s preview mat fits it into a 360
    /// box), and an upscaled box-average reads as a focus problem.
    public static let defaultLongestEdge = 360

    /// Fit `width`x`height` inside a `longestEdge` box, preserving aspect.
    ///
    /// Never scales UP: a 100 px window previewed at 240 would be a blurry
    /// enlargement of something already small enough to read.
    public static func fittedSize(
        width: Int, height: Int, longestEdge: Int = defaultLongestEdge
    ) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, longestEdge > 0 else { return nil }
        let longest = max(width, height)
        guard longest > longestEdge else { return (width, height) }
        let scale = Double(longestEdge) / Double(longest)
        // At least 1 in each axis: a 4000x2 strip scales to 240x0 otherwise,
        // and a zero-height image is a crash in whatever displays it rather
        // than a very short preview.
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// Scale a packed BGRA frame down to an RGBA thumbnail.
    ///
    /// - Parameters:
    ///   - bgra: the source frame. Read-only, and not retained.
    ///   - stride: row pitch in BYTES. **Not** `width * 4` in general — every
    ///     capture API in this repo pads rows, and reading at `width * 4`
    ///     skews the image further with every row.
    ///
    /// - Returns: nil when the geometry is unusable, rather than a
    ///   zero-sized image somebody has to notice downstream.
    public static func thumbnail(
        bgra: UnsafePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        longestEdge: Int = defaultLongestEdge
    ) -> Thumbnail? {
        guard stride >= width * bytesPerPixel,
            let target = fittedSize(width: width, height: height, longestEdge: longestEdge)
        else { return nil }

        var out = [UInt8](repeating: 255, count: target.width * target.height * bytesPerPixel)
        out.withUnsafeMutableBufferPointer { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<target.height {
                // Source band for this output row. Computed from the OUTPUT
                // index rather than accumulated, so rounding cannot drift the
                // bands out of the source by the bottom of the image.
                let y0 = row * height / target.height
                let y1 = max(y0 + 1, (row + 1) * height / target.height)
                for column in 0..<target.width {
                    let x0 = column * width / target.width
                    let x1 = max(x0 + 1, (column + 1) * width / target.width)

                    var blue = 0
                    var green = 0
                    var red = 0
                    var count = 0
                    for y in y0..<y1 {
                        let rowBase = y * stride
                        for x in x0..<x1 {
                            let pixel = rowBase + x * bytesPerPixel
                            blue += Int(bgra[pixel])
                            green += Int(bgra[pixel + 1])
                            red += Int(bgra[pixel + 2])
                            count += 1
                        }
                    }
                    guard count > 0 else { continue }
                    let destinationPixel = (row * target.width + column) * bytesPerPixel
                    // B,G,R in → R,G,B out. The swap is the whole reason this
                    // returns a distinct type rather than more BGRA.
                    destinationBase[destinationPixel] = UInt8(red / count)
                    destinationBase[destinationPixel + 1] = UInt8(green / count)
                    destinationBase[destinationPixel + 2] = UInt8(blue / count)
                    destinationBase[destinationPixel + 3] = 255
                }
            }
        }
        return Thumbnail(width: target.width, height: target.height, rgba: out)
    }

    /// How often a preview is worth producing.
    ///
    /// Once a second, not per frame. This runs on the capture thread, between a
    /// frame arriving and the encoder getting it, so the cost lands directly on
    /// the share's frame rate — and nobody watches their own thumbnail closely
    /// enough to notice it is a second stale.
    public static let intervalNs: UInt64 = 1_000_000_000

    /// Whether to produce a preview now, given when the last one was made.
    ///
    /// Pure so the throttle is testable: the alternative is a timestamp
    /// comparison buried in a capture loop, which is exactly the kind of thing
    /// that ends up firing every frame after a refactor and nobody notices
    /// except as a share that got slower.
    public static func shouldCapture(
        lastCaptureNs: UInt64?, nowNs: UInt64, intervalNs: UInt64 = intervalNs
    ) -> Bool {
        guard let lastCaptureNs else { return true }
        // Saturating rather than wrapping: a clock that went backwards (a
        // caller passing a stale `now`) must not read as "an enormous time has
        // passed" and fire on every frame.
        guard nowNs >= lastCaptureNs else { return false }
        return nowNs - lastCaptureNs >= intervalNs
    }
}
