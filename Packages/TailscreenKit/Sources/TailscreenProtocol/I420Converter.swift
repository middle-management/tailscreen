import Foundation

/// I420 → BGRA8, for renderer backends with no GPU colour conversion (the
/// Windows `WriteableBitmap` surface, and any future software fallback). In
/// the portable tier so all renderers agree on colour, not just their own.
///
/// **BT.709, either range** — getting the range wrong washes blacks to grey
/// (full-range maths on limited input) or crushes blacks/clips highlights
/// (reverse). `X11CaptureKit`/`BGRAToI420` produce limited range; macOS
/// capture is full-range 8-bit by default. Caller states which via
/// `Source.range` (defaults to limited, the codec-mandated default).
///
/// BGRA byte order, opaque alpha — what `WriteableBitmap` wants.
public enum I420Converter {
    /// Fixed-point coefficients, scaled by 2^16 — integer maths since this
    /// runs per pixel, per frame, on the UI thread, and the rounding is
    /// indistinguishable at 8 bits per channel.
    ///
    /// Same BT.709 matrix with and without the limited-range expansion
    /// folded in (limited scales luma by 255/219 after subtracting 16 and
    /// chroma by 255/224; full does neither).
    private struct Coefficients {
        let lumaOffset: Int
        let yCoeff: Int
        let vToR: Int
        let uToG: Int
        let vToG: Int
        let uToB: Int

        static let limited = Coefficients(
            lumaOffset: 16,
            yCoeff: 76309,  // 1.164383 × 65536
            vToR: 117489,  // 1.792741 × 65536
            uToG: -13975,  // -0.213249 × 65536
            vToG: -34925,  // -0.532909 × 65536
            uToB: 138438)  // 2.112402 × 65536

        static let full = Coefficients(
            lumaOffset: 0,
            yCoeff: 65536,  // 1.0 × 65536 — samples already span 0…255
            vToR: 103206,  // 1.5748 × 65536
            uToG: -12275,  // -0.1873 × 65536
            vToG: -30677,  // -0.4681 × 65536
            uToB: 121609)  // 1.8556 × 65536

        static func forRange(_ range: VideoColorRange) -> Coefficients {
            range == .full ? .full : .limited
        }
    }

    /// Half a unit in the fixed-point scale, added before the shift so the
    /// result rounds instead of truncating. Without it limited-range white
    /// (Y=235) lands on 254, not 255. A test pins the exact value.
    private static let rounding = 1 << 15

    /// The three source planes and the geometry they describe. A value
    /// rather than five arguments, mirroring `BGRAToI420.Source` (the two
    /// converters are inverses).
    public struct Source {
        public let yPlane: [UInt8]
        public let uPlane: [UInt8]
        public let vPlane: [UInt8]
        public let width: Int
        public let height: Int
        /// How the samples use their code space. Defaults to `.limited`, the
        /// codec-mandated default for a silent bitstream.
        public let range: VideoColorRange

        public init(
            yPlane: [UInt8], uPlane: [UInt8], vPlane: [UInt8], width: Int, height: Int,
            range: VideoColorRange = .limited
        ) {
            self.yPlane = yPlane
            self.uPlane = uPlane
            self.vPlane = vPlane
            self.width = width
            self.height = height
            self.range = range
        }
    }

    /// Convert I420 planes into `destination`, which must have room for
    /// `width × height × 4` bytes. Returns `false` without writing anything
    /// if the planes are smaller than the declared dimensions.
    ///
    /// Takes planes rather than a `DecodedVideoFrame` (VIEWER-tier type)
    /// because this also serves the SHARER's preview thumbnail, whose planes
    /// come straight off a capture backend. `TailscreenViewer` adds the
    /// frame-shaped overload.
    @discardableResult
    public static func convert(
        _ source: Source,
        into destination: UnsafeMutablePointer<UInt8>
    ) -> Bool {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return false }

        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        guard source.yPlane.count >= width * height,
            source.uPlane.count >= chromaWidth * chromaHeight,
            source.vPlane.count >= chromaWidth * chromaHeight
        else { return false }

        let coefficients = Coefficients.forRange(source.range)
        source.yPlane.withUnsafeBufferPointer { y in
            source.uPlane.withUnsafeBufferPointer { u in
                source.vPlane.withUnsafeBufferPointer { v in
                    for row in 0..<height {
                        let yRow = row * width
                        let chromaRow = (row / 2) * chromaWidth
                        var out = row * width * 4
                        for column in 0..<width {
                            let luma =
                                (Int(y[yRow + column]) - coefficients.lumaOffset)
                                * coefficients.yCoeff + rounding
                            let chromaIndex = chromaRow + column / 2
                            let cb = Int(u[chromaIndex]) - 128
                            let cr = Int(v[chromaIndex]) - 128

                            let r = (luma + coefficients.vToR * cr) >> 16
                            let g = (luma + coefficients.uToG * cb + coefficients.vToG * cr) >> 16
                            let b = (luma + coefficients.uToB * cb) >> 16

                            // BGRA, opaque
                            destination[out] = clamp(b)
                            destination[out + 1] = clamp(g)
                            destination[out + 2] = clamp(r)
                            destination[out + 3] = 255
                            out += 4
                        }
                    }
                }
            }
        }
        return true
    }

    @inline(__always)
    private static func clamp(_ value: Int) -> UInt8 {
        if value < 0 { return 0 }
        if value > 255 { return 255 }
        return UInt8(value)
    }
}
