import Foundation

/// I420 → BGRA8, for renderer backends that have no GPU colour conversion.
///
/// The GL and Metal renderers convert in a shader; a CPU blit path (the Windows
/// `WriteableBitmap` surface, and any future software fallback) needs the same
/// maths on the CPU. It lives in the portable tier rather than beside a
/// particular backend for the same reason `AnnotationGeometry` does: two
/// renderers disagreeing about colour would show the same stream in two
/// different sets of colours, and the constants below are the agreement.
///
/// **Limited-range BT.709**, matching what the sharers produce — `X11CaptureKit`
/// documents "BGRA→I420 (limited-range BT.709)" and the macOS capture path tags
/// BT.709 in the SPS VUI by default. Getting the range wrong is not subtle: full
/// -range maths on limited-range input washes blacks to grey and clips
/// highlights.
///
/// BGRA byte order with opaque alpha is what `WriteableBitmap` wants
/// (BGRA8, premultiplied — and premultiplying by an alpha of 255 is identity,
/// so nothing extra is needed).
public enum I420Converter {
    /// Fixed-point coefficients, scaled by 2^16.
    ///
    /// Integer maths rather than Float: this runs per pixel, per frame, on the
    /// UI thread, and the rounding is indistinguishable at 8 bits per channel.
    private static let yCoeff = 76309  // 1.164383 × 65536
    private static let vToR = 117489  // 1.792741 × 65536
    private static let uToG = -13975  // -0.213249 × 65536
    private static let vToG = -34925  // -0.532909 × 65536
    private static let uToB = 138438  // 2.112402 × 65536

    /// Half a unit in the fixed-point scale, added before the shift so the
    /// result rounds instead of truncating.
    ///
    /// Not cosmetic: without it, limited-range white (Y=235) lands on 254
    /// rather than 255, so a fully white frame is imperceptibly grey and
    /// nothing ever reaches the top of the range. A test pins that exact value.
    private static let rounding = 1 << 15

    /// Convert `frame` into `destination`, which must have room for
    /// `width × height × 4` bytes.
    ///
    /// Returns `false` without writing anything if the frame's planes are
    /// smaller than its declared dimensions — a truncated frame should show the
    /// previous picture rather than garbage or a crash, and a decoder that
    /// emits one is broken in a way the renderer cannot paper over.
    @discardableResult
    public static func convert(
        _ frame: DecodedVideoFrame,
        into destination: UnsafeMutablePointer<UInt8>
    ) -> Bool {
        let width = frame.width
        let height = frame.height
        guard width > 0, height > 0 else { return false }

        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        guard frame.yPlane.count >= width * height,
            frame.uPlane.count >= chromaWidth * chromaHeight,
            frame.vPlane.count >= chromaWidth * chromaHeight
        else { return false }

        frame.yPlane.withUnsafeBufferPointer { y in
            frame.uPlane.withUnsafeBufferPointer { u in
                frame.vPlane.withUnsafeBufferPointer { v in
                    for row in 0..<height {
                        let yRow = row * width
                        let chromaRow = (row / 2) * chromaWidth
                        var out = row * width * 4
                        for column in 0..<width {
                            let luma = (Int(y[yRow + column]) - 16) * yCoeff + rounding
                            let chromaIndex = chromaRow + column / 2
                            let cb = Int(u[chromaIndex]) - 128
                            let cr = Int(v[chromaIndex]) - 128

                            let r = (luma + vToR * cr) >> 16
                            let g = (luma + uToG * cb + vToG * cr) >> 16
                            let b = (luma + uToB * cb) >> 16

                            // BGRA, opaque.
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
