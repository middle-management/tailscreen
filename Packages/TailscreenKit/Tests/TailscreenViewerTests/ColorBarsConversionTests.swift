import XCTest

import enum TailscreenProtocol.I420Converter
import struct TailscreenProtocol.VideoColorInfo
import enum TailscreenProtocol.VideoColorRange

@testable import TailscreenViewer

/// `makeColorBarsFrame()` put through `I420Converter` — the CPU reference the
/// GL/D3D11 GPU render self-tests (which must use relative predicates, since
/// shader rounding/filtering/sRGB move values a few counts) are compared
/// against. This is the one place the bars' colours can be asserted exactly.
///
/// **Bars 2 and 3 are mid-luma, maximum-chroma, not saturated red/blue** —
/// read `makeColorBarsFrame()`'s doc comment before touching expectations.
final class ColorBarsConversionTests: XCTestCase {
    /// Byte order out of `I420Converter` is BGRA; these read as (r, g, b) so
    /// the expectations below match the doc comment's table verbatim.
    private struct RGB: Equatable, CustomStringConvertible {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        var description: String { "rgb(\(r),\(g),\(b))" }
    }

    private func converted(
        range: VideoColorRange = .limited
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        let bars = makeColorBarsFrame()
        let frame = DecodedVideoFrame(
            width: bars.width, height: bars.height,
            yPlane: bars.yPlane, uPlane: bars.uPlane, vPlane: bars.vPlane,
            colorInfo: VideoColorInfo(range: range))
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

    /// Full range (macOS sharer default): no 16..235 expansion. White is the
    /// load-bearing case — 235 must stay 235, not stretch to 255, since a
    /// full-range stream through limited-range math is the bug that shipped.
    func testFullRangeSkipsTheLimitedRangeExpansion() {
        let (pixels, width, height) = converted(range: .full)
        let barWidth = width / 4
        let sampled = (0..<4).map {
            pixel(pixels, width: width, x: $0 * barWidth + barWidth / 2, y: height / 2)
        }
        XCTAssertEqual(
            sampled,
            [
                RGB(r: 235, g: 235, b: 235),  // Y=235 is 235, NOT stretched to white
                RGB(r: 16, g: 16, b: 16),  // Y=16 is 16, NOT crushed to black
                RGB(r: 255, g: 69, b: 128),
                RGB(r: 128, g: 104, b: 255)
            ])
        // Confirms the range parameter isn't silently ignored.
        let (limitedPixels, _, _) = converted(range: .limited)
        XCTAssertNotEqual(pixels, limitedPixels)
    }

    func testEachBarIsFlatAllTheWayAcrossAndDown() {
        // A subsampling off-by-one shows up as an edge fringe, invisible to
        // the centre samples above.
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
        // A converter ignoring chroma entirely would still pass the black/
        // white checks, turning bars 2 and 3 into the same grey.
        let (pixels, width, height) = converted()
        let barWidth = width / 4
        let sampled = (0..<4).map {
            pixel(pixels, width: width, x: $0 * barWidth + barWidth / 2, y: height / 2)
        }
        XCTAssertEqual(Set(sampled.map(\.description)).count, 4)
    }
}
