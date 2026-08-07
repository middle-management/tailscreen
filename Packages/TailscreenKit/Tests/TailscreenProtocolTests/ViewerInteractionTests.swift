import XCTest

@testable import TailscreenProtocol

/// The pieces the WinUI viewer's drawing / zoom / control layer rests on, all
/// of which moved into or grew in the portable tier so Linux CI can run them —
/// the Windows runner is the authority on whether that app *links*, never on
/// whether its arithmetic is right.
final class ViewerPointerMappingTests: XCTestCase {
    func testMatchingAspectHasNoLetterbox() {
        // 16:9 video in a 16:9 pane: the content fills it, so the centre is
        // the centre and the corners are the corners.
        let mid = ViewerPointerMapping.normalize(
            point: (x: 320, y: 180), paneSize: (width: 640, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(mid.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mid.y, 0.5, accuracy: 0.0001)
    }

    func testWiderPaneLetterboxesLeftAndRight() {
        // 16:9 video in a 2:1 pane. The content is 640 wide inside a 720-wide
        // pane, so there are 40-px bars either side — and a click at the pane's
        // left edge must read as the video's left edge, not as −0.06.
        let left = ViewerPointerMapping.normalize(
            point: (x: 40, y: 0), paneSize: (width: 720, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(left.x, 0, accuracy: 0.0001)
        let right = ViewerPointerMapping.normalize(
            point: (x: 680, y: 360), paneSize: (width: 720, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(right.x, 1, accuracy: 0.0001)
    }

    func testTallerPaneLetterboxesTopAndBottom() {
        // The other branch, which a mapping written for one orientation gets
        // wrong silently: it is correct on a wide window and offset on a tall
        // one, so a developer resizing to landscape never sees it.
        let top = ViewerPointerMapping.normalize(
            point: (x: 0, y: 90), paneSize: (width: 640, height: 540),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(top.y, 0, accuracy: 0.0001)
        let bottom = ViewerPointerMapping.normalize(
            point: (x: 640, y: 450), paneSize: (width: 640, height: 540),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(bottom.y, 1, accuracy: 0.0001)
    }

    func testInsideALetterboxBarClampsToTheNearestEdge() {
        // Not an error: the pointer legitimately travels over the bars. It has
        // to land on the frame's edge, because the sharer clamps identically
        // and a value outside [0,1] would simply be clamped there instead —
        // silently, and after a round trip.
        let inBar = ViewerPointerMapping.normalize(
            point: (x: 5, y: 180), paneSize: (width: 720, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(inBar.x, 0, accuracy: 0.0001)
    }

    func testDegenerateInputsDoNotTrap() {
        XCTAssertEqual(
            ViewerPointerMapping.normalize(
                point: (x: 10, y: 10), paneSize: (width: 0, height: 0),
                videoSize: (width: 1920, height: 1080)
            ).x, 0)
        XCTAssertEqual(
            ViewerPointerMapping.normalize(
                point: (x: .nan, y: 10), paneSize: (width: 640, height: 360),
                videoSize: (width: 1920, height: 1080)
            ).x, 0)
    }

    // MARK: - fitRect
    //
    // The letterbox rect itself, which the three hosts used to re-derive
    // (GTK GL view / WinUI image view / macOS AspectFitHostView) and now all
    // read from here — the values below pin the arithmetic those inline
    // copies computed, exactly.

    private func assertRect(
        _ rect: CGRect, x: Double, y: Double, width: Double, height: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Double(rect.minX), x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(Double(rect.minY), y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(Double(rect.width), width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(Double(rect.height), height, accuracy: 1e-9, file: file, line: line)
    }

    func testFitRectLetterboxesWideVideoInTallPane() {
        // 16:9 video in a 4:3 pane: full width, bars top and bottom.
        let fit = ViewerPointerMapping.fitRect(
            paneSize: (width: 640, height: 480), videoSize: (width: 1920, height: 1080))
        assertRect(fit, x: 0, y: 60, width: 640, height: 360)
    }

    func testFitRectPillarboxesPortraitVideoInLandscapePane() {
        // Portrait 3:4 video in a 16:9 pane: full height, bars either side.
        let fit = ViewerPointerMapping.fitRect(
            paneSize: (width: 1280, height: 720), videoSize: (width: 1080, height: 1440))
        assertRect(fit, x: 370, y: 0, width: 540, height: 720)
    }

    func testFitRectExactAspectFillsThePane() {
        // Equal aspects take the pillarbox branch and compute the full pane —
        // no one-pixel sliver from a strict-inequality asymmetry.
        let fit = ViewerPointerMapping.fitRect(
            paneSize: (width: 640, height: 360), videoSize: (width: 1920, height: 1080))
        assertRect(fit, x: 0, y: 0, width: 640, height: 360)
    }

    func testFitRectDegenerateSizesReturnTheWholePane() {
        // No video yet: the content rect is the pane, which is the fallback
        // the WinUI and macOS hosts shipped (GTK guards separately and skips).
        let noVideo = ViewerPointerMapping.fitRect(
            paneSize: (width: 640, height: 360), videoSize: (width: 0, height: 1080))
        assertRect(noVideo, x: 0, y: 0, width: 640, height: 360)
        // No pane yet: degenerate in, degenerate out, no trap.
        let noPane = ViewerPointerMapping.fitRect(
            paneSize: (width: 0, height: 0), videoSize: (width: 1920, height: 1080))
        assertRect(noPane, x: 0, y: 0, width: 0, height: 0)
    }

    func testFitRectAgreesWithNormalize() {
        // The whole point of sharing the function: a pointer at the fit
        // rect's corners must normalize to exactly (0,0) and (1,1).
        let pane = (width: 733.0, height: 411.0)
        let video = (width: 2560, height: 1440)
        let fit = ViewerPointerMapping.fitRect(paneSize: pane, videoSize: video)
        let topLeft = ViewerPointerMapping.normalize(
            point: (x: Double(fit.minX), y: Double(fit.minY)), paneSize: pane, videoSize: video)
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-9)
        let bottomRight = ViewerPointerMapping.normalize(
            point: (x: Double(fit.maxX), y: Double(fit.maxY)), paneSize: pane, videoSize: video)
        XCTAssertEqual(bottomRight.x, 1, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.y, 1, accuracy: 1e-9)
    }
}

final class AnnotationCompositeTests: XCTestCase {
    private let width = 32
    private let height = 32

    /// An opaque red background, as a decoded frame would be.
    private func opaqueSurface() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 0  // B
            pixels[index + 1] = 0  // G
            pixels[index + 2] = 200  // R
            pixels[index + 3] = 255  // A
        }
        return pixels
    }

    private func withSurface(
        _ pixels: inout [UInt8], _ body: (AnnotationRasterizer.Surface) -> Void
    ) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            body(
                AnnotationRasterizer.Surface(
                    bgra: base, stride: width * 4, width: width, height: height))
        }
    }

    func testDrawKeepsWhatIsAlreadyThere() {
        // The whole reason `draw` exists: the WinUI viewer composites strokes
        // into the decoded frame, and `render`'s clear would erase the video.
        var pixels = opaqueSurface()
        let stroke = Annotation(
            id: UUID(), tool: .line,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.4, y: 0.5)],
            color: Annotation.RGBA(r: 0, g: 0, b: 1, a: 1), width: 6)
        withSurface(&pixels) { AnnotationRasterizer.draw([stroke], into: $0) }

        // A corner the stroke cannot reach still holds the background.
        let corner = (height - 1) * width * 4
        XCTAssertEqual(pixels[corner + 2], 200, "background must survive a composite")
        XCTAssertEqual(pixels[corner + 3], 255)
    }

    func testRenderStillClears() {
        // The sharer overlay's contract, unchanged by the split.
        var pixels = opaqueSurface()
        withSurface(&pixels) { AnnotationRasterizer.render([], into: $0) }
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 }, "render must clear to transparent")
    }

    func testCompositedStrokeStaysOpaque() {
        // Source-over onto an opaque destination must leave alpha at 255. If it
        // did not, the WriteableBitmap would show the stroke as a translucent
        // hole — which reads as a rendering style rather than as a bug.
        var pixels = opaqueSurface()
        let stroke = Annotation(
            id: UUID(), tool: .line,
            points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)],
            // Widths are quoted against a 1000-px short edge
            // (`referenceShortEdge`), so on a 32-px test surface a width of 300
            // is ~9.6 px — thick enough that the sampled centre pixel is fully
            // covered rather than antialiased, which is what makes the channel
            // assertion mean something.
            color: Annotation.RGBA(r: 0, g: 0, b: 1, a: 1), width: 300)
        withSurface(&pixels) { AnnotationRasterizer.draw([stroke], into: $0) }

        let centre = ((height / 2) * width + width / 2) * 4
        XCTAssertEqual(pixels[centre + 3], 255, "an opaque frame must stay opaque")
        XCTAssertEqual(pixels[centre], 255, "fully covered: the stroke's blue, not a blend")
        XCTAssertEqual(pixels[centre + 2], 0, "and none of the background's red")
    }
}

final class AnnotationStoreVisibleTests: XCTestCase {
    func testLiveStrokeIsVisibleWhileDragging() {
        // A viewer that cannot see its own stroke until the drag ends has no
        // way to tell whether drawing is working at all.
        let store = AnnotationStore()
        store.mode = .drawing(.pen)
        store.beginStroke(at: CGPoint(x: 0.1, y: 0.1))
        store.extendStroke(to: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(store.visibleAnnotations.count, 1)
        XCTAssertEqual(store.visibleAnnotations.first?.points.count, 2)
    }

    func testLiveStrokeKeepsOneIdentityAcrossTheDrag() {
        // Fixed rather than fresh per read, so a renderer that diffs by id sees
        // one stroke growing rather than a new one every frame — the same
        // upsert-not-append rule `ReceivedAnnotations` documents for the
        // relayed side.
        let store = AnnotationStore()
        store.mode = .drawing(.pen)
        store.beginStroke(at: CGPoint(x: 0.1, y: 0.1))
        let first = store.visibleAnnotations.first?.id
        store.extendStroke(to: CGPoint(x: 0.2, y: 0.2))
        XCTAssertEqual(store.visibleAnnotations.first?.id, first)
    }

    func testCommittedStrokeReplacesTheLiveOne() {
        let store = AnnotationStore()
        store.mode = .drawing(.pen)
        store.beginStroke(at: CGPoint(x: 0.1, y: 0.1))
        store.extendStroke(to: CGPoint(x: 0.4, y: 0.4))
        store.endStroke()
        // One stroke, not two: the live one must not survive its own commit.
        XCTAssertEqual(store.visibleAnnotations.count, 1)
    }

    func testRelayedStrokesAreVisibleToo() {
        // Both authors' strokes render, which is what makes annotation a shared
        // canvas rather than a private scribble.
        let store = AnnotationStore()
        let remote = Annotation(
            id: UUID(), tool: .arrow,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
            color: Annotation.RGBA.palette[1], width: 3)
        store.apply(.add(remote))
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [remote.id])
    }
}
