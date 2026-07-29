import XCTest

@testable import TailscreenProtocol

/// Tests for the two halves of displaying a viewer's annotations on a sharer
/// that has no drawing framework to hand: `AnnotationStore` (what to draw) and
/// `AnnotationRasterizer` (how).
///
/// Both exist in the portable tier for the same reason: they are the parts a
/// Windows-only implementation could not check, and the parts most likely to
/// be subtly wrong — an upsert that appends instead, a premultiply that is
/// skipped and shows up as a dark halo rather than an error.
final class AnnotationRenderingTests: XCTestCase {
    private func stroke(
        id: UUID = UUID(), tool: AnnotationTool = .pen, points: [CGPoint],
        color: Annotation.RGBA = Annotation.defaultColor, width: Double = 3
    ) -> Annotation {
        Annotation(id: id, tool: tool, points: points, color: color, width: width)
    }

    // MARK: The store

    func testADragUpdatesOneStrokeRatherThanStackingCopies() {
        // A viewer dragging a pen re-sends the SAME id with a longer point
        // list every few milliseconds. Appending would leave hundreds of
        // overlapping copies of one stroke to redraw every frame.
        var store = AnnotationStore()
        let id = UUID()
        store.apply(.add(stroke(id: id, points: [.init(x: 0, y: 0)])), nowNs: 0)
        store.apply(
            .add(stroke(id: id, points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])), nowNs: 1)

        XCTAssertEqual(store.annotations.count, 1)
        XCTAssertEqual(store.annotations.first?.points.count, 2)
    }

    func testUndoRemovesAndUnknownUndoChangesNothing() {
        var store = AnnotationStore()
        let id = UUID()
        store.apply(.add(stroke(id: id, points: [.init(x: 0, y: 0)])), nowNs: 0)

        XCTAssertFalse(store.apply(.undo(UUID()), nowNs: 0), "an unknown id is not a change")
        XCTAssertEqual(store.annotations.count, 1)
        XCTAssertTrue(store.apply(.undo(id), nowNs: 0))
        XCTAssertTrue(store.isEmpty)
    }

    func testClearAllOnAnEmptyStoreIsNotAChange() {
        var store = AnnotationStore()
        XCTAssertFalse(store.apply(.clearAll, nowNs: 0), "nothing to clear, nothing to redraw")
    }

    func testClickMarkersExpireAndOtherToolsDoNot() {
        var store = AnnotationStore()
        let click = UUID()
        store.apply(.add(stroke(id: click, tool: .click, points: [.init(x: 0.5, y: 0.5)])), nowNs: 0)
        store.apply(.add(stroke(tool: .pen, points: [.init(x: 0, y: 0)])), nowNs: 0)

        XCTAssertFalse(store.expire(nowNs: AnnotationStore.clickLifetimeNs - 1))
        XCTAssertEqual(store.annotations.count, 2)

        XCTAssertTrue(store.expire(nowNs: AnnotationStore.clickLifetimeNs))
        XCTAssertEqual(store.annotations.count, 1, "the pen stroke stays")
        XCTAssertEqual(store.annotations.first?.tool, .pen)
    }

    func testNextExpiryLetsACallerSleepInsteadOfPolling() {
        var store = AnnotationStore()
        XCTAssertNil(AnnotationStore().nextExpiryNs)
        store.apply(.add(stroke(tool: .click, points: [.init(x: 0.5, y: 0.5)])), nowNs: 1000)
        XCTAssertEqual(store.nextExpiryNs, 1000 + AnnotationStore.clickLifetimeNs)
    }

    func testUndoOfAnEphemeralStrokeAlsoDropsItsDeadline() {
        var store = AnnotationStore()
        let id = UUID()
        store.apply(.add(stroke(id: id, tool: .click, points: [.init(x: 0.5, y: 0.5)])), nowNs: 0)
        store.apply(.undo(id), nowNs: 0)
        XCTAssertNil(store.nextExpiryNs, "a removed stroke must not leave a deadline behind")
        XCTAssertFalse(store.expire(nowNs: .max))
    }

    // MARK: The rasterizer

    /// Renders into a tightly packed buffer and returns it.
    /// 400×400 rather than something tiny: `Annotation.width` is quoted
    /// against a 1000-pixel short edge, so on a 64-pixel buffer even a fat
    /// stroke is sub-pixel and every coverage assertion would be measuring the
    /// antialiasing rather than the drawing.
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

    private func pixel(_ buffer: [UInt8], x: Int, y: Int, width: Int = 400) -> (
        b: UInt8, g: UInt8, r: UInt8, a: UInt8
    ) {
        let index = (y * width + x) * 4
        return (buffer[index], buffer[index + 1], buffer[index + 2], buffer[index + 3])
    }

    func testAnEmptyListClearsToFullyTransparent() {
        // Pre-filled with 0xEE, so this also proves the clear actually runs
        // rather than the buffer merely starting empty.
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
        // UpdateLayeredWindow composites premultiplied BGRA. Getting this
        // wrong is not an error — it is a dark halo around every stroke, which
        // is exactly the kind of thing that survives to a release.
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
        // Dragging past the edge of the screen is ordinary. The visible part
        // must still draw, and nothing may be written out of bounds — which
        // the surrounding 0xEE guard bytes in `rasterize` would catch as a
        // crash under bounds checking.
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
            stroke(tool: .line, points: path, color: blue, width: 20),
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
            // Stride smaller than a row: unusable, and must not be written.
            AnnotationRasterizer.render(
                [],
                into: AnnotationRasterizer.Surface(bgra: base, stride: 4, width: 4, height: 1))
        }
        XCTAssertTrue(buffer.allSatisfy { $0 == 0x11 })
    }
}
