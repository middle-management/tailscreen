import XCTest

@testable import TailscreenProtocol

/// `CaptureOutline` — the recording indicator drawn around the captured
/// region. Composited over the sharer's desktop for the whole share, so a
/// border that fills its interior silently paints over the shared content.
final class CaptureOutlineTests: XCTestCase {

    /// A surface plus its backing store, so the pointer stays valid.
    private func makeSurface(
        width: Int, height: Int, padding: Int = 0,
        _ body: (AnnotationRasterizer.Surface) -> Void
    ) -> (bytes: [UInt8], stride: Int) {
        let stride = width * 4 + padding
        var bytes = [UInt8](repeating: 0, count: stride * height)
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            body(
                AnnotationRasterizer.Surface(
                    bgra: base, stride: stride, width: width, height: height))
        }
        return (bytes, stride)
    }

    private func pixel(_ frame: (bytes: [UInt8], stride: Int), x: Int, y: Int) -> [UInt8] {
        let offset = y * frame.stride + x * 4
        return Array(frame.bytes[offset..<(offset + 4)])
    }

    // MARK: The interior

    func testTheInteriorIsUntouched() {
        let frame = makeSurface(width: 40, height: 30) {
            CaptureOutline.draw(into: $0, thickness: 4)
        }
        for y in 4..<26 {
            for x in 4..<36 {
                XCTAssertEqual(
                    pixel(frame, x: x, y: y), [0, 0, 0, 0],
                    "interior pixel (\(x),\(y)) was painted")
            }
        }
    }

    func testAnOversizedBorderStillLeavesAnInterior() {
        // 10px tall, 6px requested: naive two 6px bars would cover everything.
        let frame = makeSurface(width: 40, height: 10) {
            CaptureOutline.draw(into: $0, thickness: 6)
        }
        let centre = pixel(frame, x: 20, y: 5)
        XCTAssertEqual(centre, [0, 0, 0, 0], "an oversized border covered the interior")
    }

    func testUsableThicknessNeverReachesHalf() {
        for size in 1...40 {
            let thickness = CaptureOutline.usableThickness(
                width: size, height: size, requested: 1000)
            XCTAssertLessThan(
                thickness * 2, size, "a \(size)px surface got a \(thickness)px border")
        }
    }

    /// Too small for any border draws nothing rather than the smallest that fits.
    func testAGeometryWithNoRoomDrawsNothing() {
        let frame = makeSurface(width: 2, height: 2) {
            CaptureOutline.draw(into: $0, thickness: 4)
        }
        XCTAssertTrue(frame.bytes.allSatisfy { $0 == 0 }, "something was drawn into a 2x2 surface")
    }

    // MARK: The border

    func testAllFourEdgesArePainted() {
        let frame = makeSurface(width: 40, height: 30) {
            CaptureOutline.draw(into: $0, thickness: 4)
        }
        XCTAssertNotEqual(pixel(frame, x: 20, y: 0), [0, 0, 0, 0], "top edge")
        XCTAssertNotEqual(pixel(frame, x: 20, y: 29), [0, 0, 0, 0], "bottom edge")
        XCTAssertNotEqual(pixel(frame, x: 0, y: 15), [0, 0, 0, 0], "left edge")
        XCTAssertNotEqual(pixel(frame, x: 39, y: 15), [0, 0, 0, 0], "right edge")
    }

    /// An off-by-one at the far edge leaves a visible one-pixel gap.
    func testEachEdgeIsExactlyAsThickAsAsked() {
        let frame = makeSurface(width: 40, height: 30) {
            CaptureOutline.draw(into: $0, thickness: 4)
        }
        for y in 0..<4 { XCTAssertNotEqual(pixel(frame, x: 20, y: y), [0, 0, 0, 0], "top row \(y)") }
        XCTAssertEqual(pixel(frame, x: 20, y: 4), [0, 0, 0, 0], "top border ran one row long")
        for x in 0..<4 {
            XCTAssertNotEqual(pixel(frame, x: x, y: 15), [0, 0, 0, 0], "left column \(x)")
        }
        XCTAssertEqual(pixel(frame, x: 4, y: 15), [0, 0, 0, 0], "left border ran one column long")
        for x in 36..<40 {
            XCTAssertNotEqual(pixel(frame, x: x, y: 15), [0, 0, 0, 0], "right column \(x)")
        }
        XCTAssertEqual(pixel(frame, x: 35, y: 15), [0, 0, 0, 0], "right border ran one column long")
    }

    func testAPaddedStrideIsHonoured() {
        let padded = makeSurface(width: 16, height: 12, padding: 37) {
            CaptureOutline.draw(into: $0, thickness: 3)
        }
        let tight = makeSurface(width: 16, height: 12) {
            CaptureOutline.draw(into: $0, thickness: 3)
        }
        for y in 0..<12 {
            for x in 0..<16 {
                XCTAssertEqual(
                    pixel(padded, x: x, y: y), pixel(tight, x: x, y: y),
                    "padding changed pixel (\(x),\(y))")
            }
        }
    }

    /// Same byte order/premultiplication as `AnnotationRasterizer`, which shares this buffer.
    func testTheBorderIsPremultipliedBGRA() {
        let colour = Annotation.RGBA(r: 1, g: 0, b: 0, a: 1)
        let frame = makeSurface(width: 20, height: 20) {
            CaptureOutline.draw(into: $0, thickness: 2, color: colour)
        }
        // Pure opaque red, in BGRA: blue 0, green 0, red 255, alpha 255.
        XCTAssertEqual(pixel(frame, x: 10, y: 0), [0, 0, 255, 255])
    }

    func testAHalfTransparentBorderIsPremultiplied() {
        let colour = Annotation.RGBA(r: 1, g: 1, b: 1, a: 0.5)
        let frame = makeSurface(width: 20, height: 20) {
            CaptureOutline.draw(into: $0, thickness: 2, color: colour)
        }
        // Premultiplied: the colour channels carry the alpha already, so a
        // half-transparent white is 128, not 255.
        XCTAssertEqual(pixel(frame, x: 10, y: 0), [128, 128, 128, 128])
    }

    // MARK: Composition

    /// The outline goes under the strokes: an edge stroke must stay visible.
    func testAnnotationsDrawOverTheOutline() {
        let width = 40
        let height = 30
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        let stroke = Annotation(
            id: UUID(), tool: .pen,
            points: [CGPoint(x: 0.0, y: 0.5), CGPoint(x: 1.0, y: 0.5)],
            color: Annotation.RGBA(r: 0, g: 1, b: 0, a: 1), width: 8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let surface = AnnotationRasterizer.Surface(
                bgra: base, stride: stride, width: width, height: height)
            CaptureOutline.draw(into: surface, thickness: 4)
            AnnotationRasterizer.draw([stroke], into: surface)
        }
        // Where the stroke crosses the left upright, green must have won.
        let offset = 15 * stride + 1 * 4
        XCTAssertGreaterThan(bytes[offset + 1], bytes[offset + 2], "the outline covered the stroke")
    }
}
