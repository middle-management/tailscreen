import Foundation

/// Converts captured BGRA8 frames to limited-range BT.709 I420 — what every
/// encoder in this repo takes, and the exact inverse of the viewer's
/// `I420Converter`.
///
/// Portable on purpose, and for the same reason as `I420Converter` and
/// `MonoPCMConverter`: it is pure arithmetic that every capture backend needs
/// and that no capture backend can test. A DXGI or a portal backend supplies a
/// BGRA buffer and a stride; the conversion is identical either side.
///
/// In `TailscreenProtocol` rather than `TailscreenSharer`, which is where a
/// capture-side helper first looks like it belongs. TailscreenSharer links
/// TailscaleKit, so a test target reaching it needs `libtailscale.a` at LINK
/// time — and the `linux-protocol` job deliberately builds no Go archive,
/// which is what makes it a cheap gate. Sitting in the dependency-free tier
/// keeps this and its round-trip test inside that gate, next to the other pure
/// shared logic there (`AnnotationGeometry`, `ViewerZoomMath`).
///
/// **This doc comment is the canonical list of who shares these constants.**
/// The other four implementations point back here rather than at each other,
/// because they did point at each other and each named a different subset.
/// Limited-range BT.709 — luma 16..235, chroma 128±112 — is implemented five
/// times in this repo, twice forward and three times inverse:
///
/// | Direction | Where | Language | Serves |
/// |---|---|---|---|
/// | BGRA → I420 | **this file** | Swift | the WGC and portal capture backends |
/// | BGRA → I420 | `CX11Capture`'s `x11cap_bgra_to_i420` | C | the X11 capture backend |
/// | I420 → RGB | `CGtkVideo`'s shader | GLSL | the GTK viewer |
/// | I420 → RGB | `CWinVideo`'s `ps_main` | HLSL | the WinUI viewer |
/// | I420 → BGRA | `I420Converter` | Swift | the CPU blit + the X11 sharer's preview |
///
/// Getting the range wrong does not fail loudly — it washes out or crushes
/// every frame — so each is pinned rather than trusted. This one round-trips
/// through `I420Converter`, which is the check neither converter can perform
/// alone; the two shaders are gated against the shared `makeColorBarsFrame()`
/// by `tailscreen --overlay-self-test` (GL, under Xvfb) and `winvideo-selftest`
/// (HLSL, under WARP), which is why that frame lives in `TailscreenViewer` and
/// not beside either renderer.
///
/// The C forward converter predates this one and is not folded into it;
/// adopting this from `X11CaptureEncoder` would remove that duplication, and is
/// queued rather than done because rewriting a working capture path was not
/// what the Windows stage that added this should touch.
public enum BGRAToI420 {
    // Fixed point at 1/16384, matching CX11Capture exactly. Y_full uses the
    // BT.709 luma weights (0.2126, 0.7152, 0.0722); the scale to studio swing
    // and the chroma normalisation ((224/255)/1.8556 and (224/255)/1.5748) are
    // folded into the coefficients.
    private static let fx: Int32 = 14
    /// Round-to-nearest rather than truncate. Without it white lands on 234
    /// instead of the studio-swing ceiling of 235, and every level below is
    /// biased dark by the same fraction — the same defect the viewer-side
    /// converter had before its tests caught it.
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
        /// Row pitch in BYTES, **not** derived from the width. Capture APIs pad
        /// rows — DXGI reports its own pitch and it is routinely wider than
        /// `width * 4` — and reading at `width * 4` skews the image
        /// progressively further with every row.
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

    /// Convert one BGRA frame into caller-provided I420 planes.
    ///
    /// The geometry and the destinations are grouped rather than passed as
    /// seven arguments: swiftlint caps a function at five, and the two structs
    /// read better at the call site anyway — a capture backend holds one
    /// `Planes` for the life of a share and rebuilds `Source` per frame.
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

        // Chroma from the 2×2 block average rather than a point sample: cheap,
        // and it avoids the shimmer point-sampling gives on text and thin
        // lines, which is most of what a shared screen contains.
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
