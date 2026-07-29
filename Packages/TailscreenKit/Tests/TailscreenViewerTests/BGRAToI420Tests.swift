import XCTest

@testable import TailscreenProtocol
@testable import TailscreenViewer

/// The sharer's capture-side colour conversion, and — more usefully — its
/// agreement with the viewer's. Pure arithmetic, so it is checked here rather
/// than by looking at a shared screen, which is the point of keeping it in the
/// portable tier.
final class BGRAToI420Tests: XCTestCase {
    /// One solid colour, `width × height`, with an optional extra row padding
    /// so the stride is not `width * 4`.
    private func solidBGRA(
        width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8, padding: Int = 0
    ) -> (pixels: [UInt8], stride: Int) {
        let stride = width * 4 + padding
        var pixels = [UInt8](repeating: 0, count: stride * height)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * stride + column * 4
                pixels[index] = b
                pixels[index + 1] = g
                pixels[index + 2] = r
                pixels[index + 3] = 255
            }
        }
        return (pixels, stride)
    }

    private func convert(
        _ source: (pixels: [UInt8], stride: Int), width: Int, height: Int
    ) -> DecodedVideoFrame {
        let sizes = BGRAToI420.planeSizes(width: width, height: height)
        var y = [UInt8](repeating: 0, count: sizes.y)
        var u = [UInt8](repeating: 0, count: sizes.chroma)
        var v = [UInt8](repeating: 0, count: sizes.chroma)
        let ok = source.pixels.withUnsafeBufferPointer { bgra in
            y.withUnsafeMutableBufferPointer { yp in
                u.withUnsafeMutableBufferPointer { up in
                    v.withUnsafeMutableBufferPointer { vp in
                        BGRAToI420.convert(
                            BGRAToI420.Source(
                                bgra: bgra.baseAddress!, stride: source.stride,
                                width: width, height: height),
                            into: BGRAToI420.Planes(
                                y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!))
                    }
                }
            }
        }
        XCTAssertTrue(ok)
        return DecodedVideoFrame(width: width, height: height, yPlane: y, uPlane: u, vPlane: v)
    }

    // MARK: - Range

    /// Black must land on the studio-swing floor, not on zero. Full-range
    /// output through a limited-range decoder is the classic crushed-blacks
    /// bug, and it looks *almost* right.
    func testBlackIsStudioSwingFloor() {
        let frame = convert(solidBGRA(width: 4, height: 4, b: 0, g: 0, r: 0), width: 4, height: 4)
        XCTAssertEqual(frame.yPlane[0], 16)
        XCTAssertEqual(frame.uPlane[0], 128)
        XCTAssertEqual(frame.vPlane[0], 128)
    }

    /// ...and white on 235, not 255. Reaching exactly 235 is what the
    /// round-to-nearest term buys; truncation stops one short.
    func testWhiteIsStudioSwingCeiling() {
        let frame = convert(
            solidBGRA(width: 4, height: 4, b: 255, g: 255, r: 255), width: 4, height: 4)
        XCTAssertEqual(frame.yPlane[0], 235)
        XCTAssertEqual(frame.uPlane[0], 128)
        XCTAssertEqual(frame.vPlane[0], 128)
    }

    /// A neutral grey must stay neutral: any chroma drift on greys means the
    /// luma weights and the chroma normalisation disagree.
    func testGreyHasNoChroma() {
        for level: UInt8 in [32, 64, 128, 192] {
            let frame = convert(
                solidBGRA(width: 4, height: 4, b: level, g: level, r: level), width: 4, height: 4)
            XCTAssertEqual(frame.uPlane[0], 128, "grey \(level) drifted in U")
            XCTAssertEqual(frame.vPlane[0], 128, "grey \(level) drifted in V")
        }
    }

    // MARK: - The round trip

    /// Convert BGRA → I420 → BGRA and require the colour to survive.
    ///
    /// This is the check neither converter can make alone. `BGRAToI420` could
    /// be self-consistently wrong about the range and every test above it would
    /// still pass; so could `I420Converter`. Agreeing with each other on
    /// saturated colours pins both to the same BT.709 limited-range contract —
    /// and that contract is also what `CX11Capture` and `CGtkVideo` implement,
    /// so a drift here is a drift against all four.
    ///
    /// The tolerance is loose on purpose: two fixed-point conversions in
    /// opposite directions, plus 4:2:0 chroma subsampling, cannot be exact.
    /// What must survive is the *colour*, not the exact byte.
    func testRoundTripPreservesColour() {
        let cases: [(name: String, b: UInt8, g: UInt8, r: UInt8)] = [
            ("black", 0, 0, 0),
            ("white", 255, 255, 255),
            ("mid grey", 128, 128, 128),
            ("red", 0, 0, 255),
            ("green", 0, 255, 0),
            ("blue", 255, 0, 0),
            ("orange", 0, 128, 255)
        ]
        for test in cases {
            let width = 8
            let height = 8
            let frame = convert(
                solidBGRA(width: width, height: height, b: test.b, g: test.g, r: test.r),
                width: width, height: height)

            var out = [UInt8](repeating: 0, count: width * height * 4)
            let ok = out.withUnsafeMutableBufferPointer {
                I420Converter.convert(frame, into: $0.baseAddress!)
            }
            XCTAssertTrue(ok)

            // Sample a pixel away from the edges: the chroma loop covers whole
            // 2×2 blocks, so the last row/column of an odd size is a separate
            // concern (covered below).
            let index = (2 * width + 2) * 4
            XCTAssertEqual(Int(out[index]), Int(test.b), accuracy: 8, "\(test.name) blue")
            XCTAssertEqual(Int(out[index + 1]), Int(test.g), accuracy: 8, "\(test.name) green")
            XCTAssertEqual(Int(out[index + 2]), Int(test.r), accuracy: 8, "\(test.name) red")
            XCTAssertEqual(out[index + 3], 255, "\(test.name) alpha")
        }
    }

    /// A greyscale ramp must come back monotonic. Banding or inversion in the
    /// middle of the range is invisible on solid-colour tests.
    func testRoundTripKeepsAGreyRampMonotonic() {
        let width = 16
        let height = 4
        let stride = width * 4
        var pixels = [UInt8](repeating: 255, count: stride * height)
        for row in 0..<height {
            for column in 0..<width {
                let level = UInt8(column * 16)
                let index = row * stride + column * 4
                pixels[index] = level
                pixels[index + 1] = level
                pixels[index + 2] = level
            }
        }
        let frame = convert((pixels, stride), width: width, height: height)

        var out = [UInt8](repeating: 0, count: width * height * 4)
        _ = out.withUnsafeMutableBufferPointer { I420Converter.convert(frame, into: $0.baseAddress!) }

        var previous = -1
        for column in 0..<width {
            let value = Int(out[column * 4 + 1])  // green channel of a grey
            XCTAssertGreaterThanOrEqual(value, previous, "ramp inverted at column \(column)")
            previous = value
        }
    }

    // MARK: - Geometry

    /// Capture APIs pad rows. DXGI reports its own pitch and it is routinely
    /// wider than `width * 4`; reading at `width * 4` would skew the image
    /// progressively down the frame.
    func testStridePaddingIsHonoured() {
        let unpadded = convert(
            solidBGRA(width: 4, height: 4, b: 0, g: 128, r: 255), width: 4, height: 4)
        let padded = convert(
            solidBGRA(width: 4, height: 4, b: 0, g: 128, r: 255, padding: 64), width: 4, height: 4)
        XCTAssertEqual(unpadded.yPlane, padded.yPlane)
        XCTAssertEqual(unpadded.uPlane, padded.uPlane)
        XCTAssertEqual(unpadded.vPlane, padded.vPlane)
    }

    /// Odd dimensions round the chroma planes up. The chroma loop only walks
    /// whole 2×2 blocks, so the trailing row/column keeps its initial value —
    /// what must not happen is a write past the end or a refusal.
    func testOddDimensionsAreAccepted() {
        let sizes = BGRAToI420.planeSizes(width: 5, height: 5)
        XCTAssertEqual(sizes.y, 25)
        XCTAssertEqual(sizes.chroma, 9)
        let frame = convert(solidBGRA(width: 5, height: 5, b: 10, g: 20, r: 30), width: 5, height: 5)
        XCTAssertEqual(frame.yPlane.count, 25)
        XCTAssertEqual(frame.uPlane.count, 9)
    }

    /// A stride narrower than the row is a caller bug, and reading it would run
    /// off the buffer. Refused rather than clamped.
    func testTooNarrowStrideIsRefused() {
        var pixels = [UInt8](repeating: 0, count: 64)
        var y = [UInt8](repeating: 7, count: 16)
        var u = [UInt8](repeating: 7, count: 4)
        var v = [UInt8](repeating: 7, count: 4)
        let ok = pixels.withUnsafeMutableBufferPointer { bgra in
            y.withUnsafeMutableBufferPointer { yp in
                u.withUnsafeMutableBufferPointer { up in
                    v.withUnsafeMutableBufferPointer { vp in
                        BGRAToI420.convert(
                            BGRAToI420.Source(
                                bgra: bgra.baseAddress!, stride: 4,  // needs 16
                                width: 4, height: 4),
                            into: BGRAToI420.Planes(
                                y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!))
                    }
                }
            }
        }
        XCTAssertFalse(ok)
        XCTAssertTrue(y.allSatisfy { $0 == 7 }, "destination left untouched")
    }
}
