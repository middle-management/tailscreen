import XCTest

@testable import TailscreenProtocol

/// Displaying a viewer's annotations on a sharer with no drawing framework:
/// `ReceivedAnnotations` (what to draw) and `AnnotationRasterizer` (how).
final class AnnotationRenderingTests: XCTestCase {
    private func stroke(
        id: UUID = UUID(), tool: AnnotationTool = .pen, points: [CGPoint],
        color: Annotation.RGBA = Annotation.defaultColor, width: Double = 3
    ) -> Annotation {
        Annotation(id: id, tool: tool, points: points, color: color, width: width)
    }

    // MARK: The store

    func testADragUpdatesOneStrokeRatherThanStackingCopies() {
        // A dragging pen re-sends the same id with a longer point list; must upsert, not append.
        var store = ReceivedAnnotations()
        let id = UUID()
        store.apply(.add(stroke(id: id, points: [.init(x: 0, y: 0)])), nowNs: 0)
        store.apply(
            .add(stroke(id: id, points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])), nowNs: 1)

        XCTAssertEqual(store.annotations.count, 1)
        XCTAssertEqual(store.annotations.first?.points.count, 2)
    }

    func testUndoRemovesAndUnknownUndoChangesNothing() {
        var store = ReceivedAnnotations()
        let id = UUID()
        store.apply(.add(stroke(id: id, points: [.init(x: 0, y: 0)])), nowNs: 0)

        XCTAssertFalse(store.apply(.undo(UUID()), nowNs: 0), "an unknown id is not a change")
        XCTAssertEqual(store.annotations.count, 1)
        XCTAssertTrue(store.apply(.undo(id), nowNs: 0))
        XCTAssertTrue(store.isEmpty)
    }

    func testClearAllOnAnEmptyStoreIsNotAChange() {
        var store = ReceivedAnnotations()
        XCTAssertFalse(store.apply(.clearAll, nowNs: 0), "nothing to clear, nothing to redraw")
    }

    func testClickMarkersExpireAndOtherToolsDoNot() {
        var store = ReceivedAnnotations()
        let click = UUID()
        store.apply(.add(stroke(id: click, tool: .click, points: [.init(x: 0.5, y: 0.5)])), nowNs: 0)
        store.apply(.add(stroke(tool: .pen, points: [.init(x: 0, y: 0)])), nowNs: 0)

        XCTAssertFalse(store.expire(nowNs: ReceivedAnnotations.clickLifetimeNs - 1))
        XCTAssertEqual(store.annotations.count, 2)

        XCTAssertTrue(store.expire(nowNs: ReceivedAnnotations.clickLifetimeNs))
        XCTAssertEqual(store.annotations.count, 1, "the pen stroke stays")
        XCTAssertEqual(store.annotations.first?.tool, .pen)
    }

    func testNextExpiryLetsACallerSleepInsteadOfPolling() {
        var store = ReceivedAnnotations()
        XCTAssertNil(ReceivedAnnotations().nextExpiryNs)
        store.apply(.add(stroke(tool: .click, points: [.init(x: 0.5, y: 0.5)])), nowNs: 1000)
        XCTAssertEqual(store.nextExpiryNs, 1000 + ReceivedAnnotations.clickLifetimeNs)
    }

    func testUndoOfAnEphemeralStrokeAlsoDropsItsDeadline() {
        var store = ReceivedAnnotations()
        let id = UUID()
        store.apply(.add(stroke(id: id, tool: .click, points: [.init(x: 0.5, y: 0.5)])), nowNs: 0)
        store.apply(.undo(id), nowNs: 0)
        XCTAssertNil(store.nextExpiryNs, "a removed stroke must not leave a deadline behind")
        XCTAssertFalse(store.expire(nowNs: .max))
    }

    // MARK: The rasterizer

    /// 400×400: `Annotation.width` is quoted against a 1000px short edge, so a
    /// smaller buffer would make strokes sub-pixel and assertions measure
    /// antialiasing instead of drawing.
    private func rasterize(
        _ annotations: [Annotation], width: Int = 400, height: Int = 400
    ) -> [UInt8] {
        var buffer = [UInt8](repeating: 0xEE, count: width * height * 4)
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            AnnotationRasterizer.render(
                annotations,
                into: AnnotationRasterizer.Surface(
                    bgra: base, stride: width * 4, width: width, height: height))
        }
        return buffer
    }

    private func pixel(
        _ buffer: [UInt8], x: Int, y: Int, width: Int = 400
    ) -> (
        b: UInt8, g: UInt8, r: UInt8, a: UInt8
    ) {
        let index = (y * width + x) * 4
        return (buffer[index], buffer[index + 1], buffer[index + 2], buffer[index + 3])
    }

    func testAnEmptyListClearsToFullyTransparent() {
        // Pre-filled with 0xEE, so this proves the clear runs rather than the buffer starting empty.
        let buffer = rasterize([])
        XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
    }

    func testAHorizontalLineCoversItsPathAndNothingElse() {
        let line = stroke(
            tool: .line, points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)], width: 20)
        let buffer = rasterize([line])

        let onLine = pixel(buffer, x: 200, y: 200)
        XCTAssertGreaterThan(onLine.a, 200, "the middle of the stroke is opaque")
        XCTAssertGreaterThan(onLine.r, 100, "the default colour is red")

        XCTAssertEqual(pixel(buffer, x: 200, y: 40).a, 0, "well above the line is untouched")
        XCTAssertEqual(pixel(buffer, x: 8, y: 200).a, 0, "before the start is untouched")
    }

    func testColoursArePremultipliedByAlpha() {
        // UpdateLayeredWindow composites premultiplied BGRA; getting this wrong is a silent dark halo, not a crash.
        let half = Annotation.RGBA(r: 1, g: 0, b: 0, a: 0.5)
        let line = stroke(
            tool: .line, points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)],
            color: half, width: 20)
        let buffer = rasterize([line])
        let onLine = pixel(buffer, x: 200, y: 200)

        XCTAssertEqual(Int(onLine.a), 128, accuracy: 4, "half alpha")
        XCTAssertEqual(
            Int(onLine.r), Int(onLine.a), accuracy: 4,
            "a fully-red pixel at 50% alpha stores r == a when premultiplied")
    }

    func testStrokesOffTheEdgeAreClippedNotRejected() {
        // The visible part must still draw; nothing may write out of bounds (the 0xEE guard bytes would catch it).
        let line = stroke(
            tool: .line, points: [.init(x: -2, y: 0.5), .init(x: 0.5, y: 0.5)], width: 20)
        let buffer = rasterize([line])
        XCTAssertGreaterThan(pixel(buffer, x: 20, y: 200).a, 0, "the on-screen part drew")
        XCTAssertEqual(pixel(buffer, x: 380, y: 200).a, 0, "past the end is untouched")
    }

    func testLaterStrokesDrawOverEarlierOnes() {
        let red = Annotation.RGBA(r: 1, g: 0, b: 0, a: 1)
        let blue = Annotation.RGBA(r: 0, g: 0, b: 1, a: 1)
        let path: [CGPoint] = [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)]
        let buffer = rasterize([
            stroke(tool: .line, points: path, color: red, width: 20),
            stroke(tool: .line, points: path, color: blue, width: 20)
        ])
        let onLine = pixel(buffer, x: 200, y: 200)
        XCTAssertGreaterThan(onLine.b, 200)
        XCTAssertLessThan(onLine.r, 60)
    }

    func testAClickMarkerDrawsARingRatherThanADot() {
        let click = stroke(tool: .click, points: [.init(x: 0.5, y: 0.5)], width: 20)
        let buffer = rasterize([click])
        XCTAssertEqual(pixel(buffer, x: 200, y: 200).a, 0, "the centre of a ring is empty")
        XCTAssertTrue(
            (0..<400).contains { pixel(buffer, x: $0, y: 200).a > 0 },
            "something was drawn on the marker's row")
    }

    func testADegenerateBufferIsRefusedRatherThanWritten() {
        var buffer = [UInt8](repeating: 0x11, count: 16)
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            // Stride smaller than a row: must be refused, not written.
            AnnotationRasterizer.render(
                [],
                into: AnnotationRasterizer.Surface(bgra: base, stride: 4, width: 4, height: 1))
        }
        XCTAssertTrue(buffer.allSatisfy { $0 == 0x11 })
    }
}
