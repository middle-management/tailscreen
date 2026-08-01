import XCTest

@testable import TailscreenViewer

/// The CPU colour conversion the Windows renderer blits through. Pure maths, so
/// it is verified here rather than by looking at a Windows screen — which is the
/// point of keeping it in the portable tier.
final class I420ConverterTests: XCTestCase {
    /// Build a solid-colour I420 frame.
    private func solid(
        width: Int, height: Int, y: UInt8, u: UInt8, v: UInt8
    ) -> DecodedVideoFrame {
        let chromaCount = ((width + 1) / 2) * ((height + 1) / 2)
        return DecodedVideoFrame(
            width: width,
            height: height,
            yPlane: [UInt8](repeating: y, count: width * height),
            uPlane: [UInt8](repeating: u, count: chromaCount),
            vPlane: [UInt8](repeating: v, count: chromaCount)
        )
    }

    private func convert(_ frame: DecodedVideoFrame) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        let ok = out.withUnsafeMutableBufferPointer {
            I420Converter.convert(frame, into: $0.baseAddress!)
        }
        XCTAssertTrue(ok)
        return out
    }

    /// Limited-range black is Y=16, not Y=0. Getting this wrong is the classic
    /// washed-out-blacks bug, and it looks "nearly right" on screen.
    func testLimitedRangeBlack() {
        let out = convert(solid(width: 2, height: 2, y: 16, u: 128, v: 128))
        XCTAssertEqual(Array(out[0..<4]), [0, 0, 0, 255])
    }

    /// ...and limited-range white is Y=235, not 255.
    func testLimitedRangeWhite() {
        let out = convert(solid(width: 2, height: 2, y: 235, u: 128, v: 128))
        XCTAssertEqual(Array(out[0..<4]), [255, 255, 255, 255])
    }

    /// Y beyond the limited range must clamp rather than wrap. A wrap would turn
    /// a superwhite highlight into a black hole.
    func testOutOfRangeClamps() {
        let low = convert(solid(width: 2, height: 2, y: 0, u: 128, v: 128))
        XCTAssertEqual(Array(low[0..<3]), [0, 0, 0])
        let high = convert(solid(width: 2, height: 2, y: 255, u: 128, v: 128))
        XCTAssertEqual(Array(high[0..<3]), [255, 255, 255])
    }

    /// Byte order is BGRA, not RGBA — swapping them is invisible on greys and
    /// glaring on anything else, so it is pinned with a saturated colour.
    func testRedIsInTheThirdByte() {
        // BT.709 red: high V, low U.
        let out = convert(solid(width: 2, height: 2, y: 63, u: 102, v: 240))
        let b = out[0]
        let g = out[1]
        let r = out[2]
        let a = out[3]
        XCTAssertEqual(a, 255)
        XCTAssertGreaterThan(r, 200, "red belongs in byte 2")
        XCTAssertLessThan(b, 80)
        XCTAssertLessThan(g, 80)
    }

    /// Chroma is half-resolution: both pixels of a 2×1 pair read the same
    /// chroma sample. An off-by-one in the subsampling index shows up as colour
    /// fringing on vertical edges.
    func testChromaIsSharedAcrossThePair() {
        var frame = solid(width: 4, height: 2, y: 128, u: 128, v: 128)
        // Two chroma columns; make them differ.
        frame = DecodedVideoFrame(
            width: 4, height: 2,
            yPlane: frame.yPlane,
            uPlane: [40, 200, 40, 200],
            vPlane: [128, 128, 128, 128]
        )
        let out = convert(frame)
        let pixel0 = Array(out[0..<3])
        let pixel1 = Array(out[4..<7])
        let pixel2 = Array(out[8..<11])
        XCTAssertEqual(pixel0, pixel1, "pixels 0 and 1 share a chroma sample")
        XCTAssertNotEqual(pixel1, pixel2, "pixel 2 uses the next chroma sample")
    }

    /// Odd dimensions round chroma up; the guard must not reject a valid frame.
    func testOddDimensions() {
        let out = convert(solid(width: 3, height: 3, y: 16, u: 128, v: 128))
        XCTAssertEqual(out.count, 3 * 3 * 4)
        XCTAssertEqual(Array(out[0..<4]), [0, 0, 0, 255])
    }

    /// A frame whose planes are too small is refused rather than read past.
    func testTruncatedPlanesRefused() {
        let frame = DecodedVideoFrame(
            width: 16, height: 16,
            yPlane: [UInt8](repeating: 128, count: 4),
            uPlane: [UInt8](repeating: 128, count: 4),
            vPlane: [UInt8](repeating: 128, count: 4)
        )
        var out = [UInt8](repeating: 7, count: 16 * 16 * 4)
        let ok = out.withUnsafeMutableBufferPointer {
            I420Converter.convert(frame, into: $0.baseAddress!)
        }
        XCTAssertFalse(ok)
        XCTAssertTrue(out.allSatisfy { $0 == 7 }, "destination left untouched")
    }
}
