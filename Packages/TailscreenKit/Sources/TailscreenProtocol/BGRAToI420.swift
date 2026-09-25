import Foundation

/// Converts captured BGRA8 frames to limited-range BT.709 I420 — what every
/// encoder in this repo takes, and the exact inverse of the viewer's
/// `I420Converter`. Portable pure arithmetic, like `I420Converter` and
/// `MonoPCMConverter`, so any capture backend (DXGI, portal) gets an
/// identical conversion.
///
/// Lives in `TailscreenProtocol`, not `TailscreenSharer`, so its round-trip
/// test stays inside the `linux-protocol` job — `TailscreenSharer` links
/// TailscaleKit, which needs `libtailscale.a` at link time.
///
/// **This doc comment is the canonical list of who shares these constants.**
/// The other four implementations point back here rather than at each other,
/// because they did point at each other and each named a different subset.
/// Limited-range BT.709 — luma 16..235, chroma 128±112 — is implemented five
/// times in this repo, twice forward and three times inverse:
///
/// | Direction | Where | Language | Serves | Range |
/// |---|---|---|---|---|
/// | BGRA → I420 | **this file** | Swift | the WGC and portal capture backends | limited only |
/// | BGRA → I420 | `CX11Capture`'s `x11cap_bgra_to_i420` | C | the X11 capture backend | limited only |
/// | I420 → RGB | `CGtkVideo`'s shader | GLSL | the GTK viewer | either (`uFullRange`) |
/// | I420 → RGB | `CWinVideo`'s `ps_main` | HLSL | the WinUI viewer | either (`fullRange`) |
/// | I420 → BGRA | `I420Converter` | Swift | the CPU blit + the X11 sharer's preview | either (`Source.range`) |
///
/// The three inverse implementations take a range; the two forward ones do
/// not — deliberate, since a capture backend knows what it produces (limited)
/// while a viewer must honour whatever range the decoder reports
/// (`VideoColorInfo`).
///
/// Getting the range wrong fails silently (washed-out or crushed frames), so
/// each is pinned: this one round-trips through `I420Converter`; the shaders
/// are gated against `makeColorBarsFrame()` via `tailscreen
/// --overlay-self-test` and `winvideo-selftest`; full-range arithmetic is
/// pinned by `ColorBarsConversionTests`.
///
/// The C forward converter predates this one and isn't folded into it —
/// queued, not done, to avoid rewriting a working capture path.
public enum BGRAToI420 {
    // Fixed point at 1/16384, matching CX11Capture exactly. Y_full uses the
    // BT.709 luma weights (0.2126, 0.7152, 0.0722); the scale to studio swing
    // and the chroma normalisation ((224/255)/1.8556 and (224/255)/1.5748) are
    // folded into the coefficients.
    private static let fx: Int32 = 14
    /// Round-to-nearest, not truncate — without it white lands on 234 instead
    /// of the studio-swing ceiling 235, biasing every level dark.
    private static let rounding: Int32 = 1 << (14 - 1)
    private static let cYR: Int32 = 3483
    private static let cYG: Int32 = 11718
    private static let cYB: Int32 = 1183
    private static let cYScale: Int32 = 14070  // 219/255 in Q14
    private static let cU: Int32 = 7756
    private static let cV: Int32 = 9139

    /// A captured BGRA frame: where the pixels are and how they are laid out.
    public struct Source {
        public let bgra: UnsafePointer<UInt8>
        /// Row pitch in bytes, not derived from the width — DXGI's pitch is
        /// routinely wider than `width * 4`, and assuming otherwise skews the image row by row.
        public let stride: Int
        public let width: Int
        public let height: Int

        public init(bgra: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) {
            self.bgra = bgra
            self.stride = stride
            self.width = width
            self.height = height
        }
    }

    /// The three destination planes, sized per ``planeSizes(width:height:)``.
    public struct Planes {
        public let y: UnsafeMutablePointer<UInt8>
        public let u: UnsafeMutablePointer<UInt8>
        public let v: UnsafeMutablePointer<UInt8>

        public init(
            y: UnsafeMutablePointer<UInt8>,
            u: UnsafeMutablePointer<UInt8>,
            v: UnsafeMutablePointer<UInt8>
        ) {
            self.y = y
            self.u = u
            self.v = v
        }
    }

    /// Number of bytes an I420 frame of this size occupies, per plane.
    public static func planeSizes(width: Int, height: Int) -> (y: Int, chroma: Int) {
        (width * height, ((width + 1) / 2) * ((height + 1) / 2))
    }

    /// Convert one BGRA frame into caller-provided I420 planes. Geometry and
    /// destinations are grouped, not seven arguments: a capture backend holds
    /// one `Planes` for the share's life and rebuilds `Source` per frame.
    ///
    /// - Returns: false, without writing, if the geometry is unusable.
    @discardableResult
    public static func convert(_ source: Source, into planes: Planes) -> Bool {
        let bgra = source.bgra
        let stride = source.stride
        let width = source.width
        let height = source.height
        let y = planes.y
        let u = planes.u
        let v = planes.v
        guard width > 0, height > 0, stride >= width * 4 else { return false }

        for row in 0..<height {
            let source = bgra + row * stride
            let destination = y + row * width
            for column in 0..<width {
                let pixel = source + column * 4
                let luma =
                    (cYR * Int32(pixel[2]) + cYG * Int32(pixel[1]) + cYB * Int32(pixel[0])
                        + rounding) >> fx
                destination[column] = clamp(16 + ((cYScale * luma + rounding) >> fx))
            }
        }

        // 2×2 block average, not a point sample: avoids shimmer on text/thin lines.
        let chromaWidth = (width + 1) / 2
        var row = 0
        while row + 1 < height {
            let row0 = bgra + row * stride
            let row1 = row0 + stride
            let uDestination = u + (row / 2) * chromaWidth
            let vDestination = v + (row / 2) * chromaWidth
            var column = 0
            while column + 1 < width {
                let a = row0 + column * 4
                let b = a + 4
                let c = row1 + column * 4
                let d = c + 4
                let blue = (Int32(a[0]) + Int32(b[0]) + Int32(c[0]) + Int32(d[0]) + 2) >> 2
                let green = (Int32(a[1]) + Int32(b[1]) + Int32(c[1]) + Int32(d[1]) + 2) >> 2
                let red = (Int32(a[2]) + Int32(b[2]) + Int32(c[2]) + Int32(d[2]) + 2) >> 2
                let luma = (cYR * red + cYG * green + cYB * blue + rounding) >> fx
                uDestination[column / 2] = clamp(128 + ((cU * (blue - luma) + rounding) >> fx))
                vDestination[column / 2] = clamp(128 + ((cV * (red - luma) + rounding) >> fx))
                column += 2
            }
            row += 2
        }

        return true
    }

    private static func clamp(_ value: Int32) -> UInt8 {
        UInt8(value < 0 ? 0 : (value > 255 ? 255 : value))
    }
}
