import Foundation

/// Downscale a captured BGRA frame to a small RGBA thumbnail — the sharer's
/// own "this is what they can see" preview.
///
/// **RGBA out, BGRA in**: the GUI hubs display via `SwiftCrossUI.Image`,
/// whose in-memory initializer wants packed R,G,B,A, while capture APIs hand
/// back BGRA. Swapping here does it once, in the same pass as the scale.
/// Getting it wrong doesn't fail loudly — it renders with red/blue swapped,
/// reading as a colour-management issue rather than a bug.
///
/// **Box-averaging, not nearest**: a screen thumbnail is mostly text.
/// Point-sampling a 4K desktop down to 160px keeps one pixel in 24 and turns
/// text into noise; averaging the block turns it into readable grey.
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

    /// The longest edge a preview is scaled to fit within. Small on purpose
    /// (produced repeatedly for the life of a share, on the capture thread).
    /// 360 matches `ShareCard`'s preview mat.
    public static let defaultLongestEdge = 360

    /// Fit `width`x`height` inside a `longestEdge` box, preserving aspect.
    /// Never scales UP: a blurry enlargement of something already readable.
    public static func fittedSize(
        width: Int, height: Int, longestEdge: Int = defaultLongestEdge
    ) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, longestEdge > 0 else { return nil }
        let longest = max(width, height)
        guard longest > longestEdge else { return (width, height) }
        let scale = Double(longestEdge) / Double(longest)
        // At least 1 in each axis: a zero-height image crashes whatever
        // displays it rather than showing a short preview.
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
                // Computed from the OUTPUT index, not accumulated, so
                // rounding can't drift the bands off by the image's bottom.
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
                    // B,G,R in → R,G,B out.
                    destinationBase[destinationPixel] = UInt8(red / count)
                    destinationBase[destinationPixel + 1] = UInt8(green / count)
                    destinationBase[destinationPixel + 2] = UInt8(blue / count)
                    destinationBase[destinationPixel + 3] = 255
                }
            }
        }
        return Thumbnail(width: target.width, height: target.height, rgba: out)
    }

    /// How often a preview is worth producing. Once a second, not per frame
    /// — this runs on the capture thread between a frame arriving and the
    /// encoder getting it, so cost lands directly on frame rate.
    public static let intervalNs: UInt64 = 1_000_000_000

    /// Whether to produce a preview now, given when the last one was made.
    /// Pure so the throttle is testable rather than a timestamp comparison
    /// buried in a capture loop.
    public static func shouldCapture(
        lastCaptureNs: UInt64?, nowNs: UInt64, intervalNs: UInt64 = intervalNs
    ) -> Bool {
        guard let lastCaptureNs else { return true }
        // Saturating, not wrapping: a clock going backwards must not read as
        // an enormous elapsed time and fire on every frame.
        guard nowNs >= lastCaptureNs else { return false }
        return nowNs - lastCaptureNs >= intervalNs
    }
}
