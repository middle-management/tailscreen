import XCTest

@testable import TailscreenViewer

import enum TailscreenProtocol.I420Converter

/// `makeColorBarsFrame()` put through `I420Converter` — the CPU reference the
/// two GPU render self-tests are compared against.
///
/// The fixture and the converter are both in the portable tier, so this is the
/// one place the bars' colours can be asserted EXACTLY. That is the whole point
/// of it: the GL (Xvfb) and D3D11 (WARP) self-tests must use relative predicates
/// — a shader's own rounding, texture filtering and any sRGB handling move
/// values by a few counts — but nothing sits between these planes and these
/// bytes. If a self-test's relative predicate ever passes while this fails, the
/// disagreement is in the maths, not in a driver.
///
/// **Bars 2 and 3 are mid-luma, maximum-chroma colours, not saturated red and
/// blue** — read `makeColorBarsFrame()`'s doc comment before touching the
/// expectations here. The first Windows self-test asserted rgb(235,16,16) ±24
/// for bar 2 and would have failed a perfectly correct render by 47 on the
/// green channel.
final class ColorBarsConversionTests: XCTestCase {
    /// Byte order out of `I420Converter` is BGRA; these read as (r, g, b) so
    /// the expectations below match the doc comment's table verbatim.
    private struct RGB: Equatable, CustomStringConvertible {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        var description: String { "rgb(\(r),\(g),\(b))" }
    }

    private func converted() -> (pixels: [UInt8], width: Int, height: Int) {
        let frame = makeColorBarsFrame()
        var out = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        let ok = out.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return I420Converter.convert(frame, into: base)
        }
        XCTAssertTrue(ok, "the fixture's planes must satisfy the converter's size guard")
        return (out, frame.width, frame.height)
    }

    private func pixel(_ buffer: [UInt8], width: Int, x: Int, y: Int) -> RGB {
        let base = (y * width + x) * 4
        XCTAssertEqual(buffer[base + 3], 255, "opaque alpha at (\(x),\(y))")
        return RGB(r: buffer[base + 2], g: buffer[base + 1], b: buffer[base])
    }

    func testTheFourBarsLandOnTheirDocumentedColours() {
        let (pixels, width, height) = converted()
        // Four equal vertical bars; sample each one's middle so a one-column
        // boundary error cannot be mistaken for a colour error.
        let barWidth = width / 4
        let y = height / 2
        let sampled = (0..<4).map { pixel(pixels, width: width, x: $0 * barWidth + barWidth / 2, y: y) }

        XCTAssertEqual(
            sampled,
            [
                RGB(r: 255, g: 255, b: 255),  // Y=235 — limited-range WHITE, not Y=255
                RGB(r: 0, g: 0, b: 0),  // Y=16 — limited-range BLACK, not Y=0
                RGB(r: 255, g: 63, b: 130),  // Y=128, V=255: mid-luma max chroma, NOT red
                RGB(r: 130, g: 103, b: 255)  // Y=128, U=255: mid-luma max chroma, NOT blue
            ])
    }

    func testEachBarIsFlatAllTheWayAcrossAndDown() {
        // Chroma is half-resolution, so a subsampling off-by-one shows up as a
        // fringe at a bar edge rather than as a wrong colour in the middle —
        // invisible to the centre samples above.
        let (pixels, width, height) = converted()
        let barWidth = width / 4
        for bar in 0..<4 {
            let reference = pixel(pixels, width: width, x: bar * barWidth, y: 0)
            for x in (bar * barWidth)..<((bar + 1) * barWidth) {
                for y in [0, height / 2, height - 1] {
                    XCTAssertEqual(
                        pixel(pixels, width: width, x: x, y: y), reference,
                        "bar \(bar) is not flat at (\(x),\(y))")
                }
            }
        }
    }

    func testTheBarsAreFourDISTINCTColours() {
        // A converter that ignored chroma entirely would still pass a "white is
        // white, black is black" check and turn bars 2 and 3 into the same grey.
        let (pixels, width, height) = converted()
        let barWidth = width / 4
        let sampled = (0..<4).map {
            pixel(pixels, width: width, x: $0 * barWidth + barWidth / 2, y: height / 2)
        }
        XCTAssertEqual(Set(sampled.map(\.description)).count, 4)
    }
}
