import XCTest

@testable import TailscreenProtocol

/// The pieces the WinUI viewer's drawing/zoom/control layer rests on, moved
/// into the portable tier so Linux CI can run them — the Windows runner
/// checks that the app links, never whether its arithmetic is right.
final class ViewerPointerMappingTests: XCTestCase {
    func testMatchingAspectHasNoLetterbox() {
        let mid = ViewerPointerMapping.normalize(
            point: (x: 320, y: 180), paneSize: (width: 640, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(mid.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mid.y, 0.5, accuracy: 0.0001)
    }

    /// A click at the pane's left edge (40px bar) must read as the video's
    /// left edge, not as -0.06.
    func testWiderPaneLetterboxesLeftAndRight() {
        let left = ViewerPointerMapping.normalize(
            point: (x: 40, y: 0), paneSize: (width: 720, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(left.x, 0, accuracy: 0.0001)
        let right = ViewerPointerMapping.normalize(
            point: (x: 680, y: 360), paneSize: (width: 720, height: 360),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(right.x, 1, accuracy: 0.0001)
    }

    /// The other branch — correct on a wide window, offset on a tall one,
    /// so a developer resizing to landscape never sees it.
    func testTallerPaneLetterboxesTopAndBottom() {
        let top = ViewerPointerMapping.normalize(
            point: (x: 0, y: 90), paneSize: (width: 640, height: 540),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(top.y, 0, accuracy: 0.0001)
        let bottom = ViewerPointerMapping.normalize(
            point: (x: 640, y: 450), paneSize: (width: 640, height: 540),
            videoSize: (width: 1920, height: 1080))
        XCTAssertEqual(bottom.y, 1, accuracy: 0.0001)
    }

    /// Not an error: the pointer legitimately travels over the bars, and
    /// must land on the frame's edge since the sharer clamps identically.
    func testInsideALetterboxBarClampsToTheNearestEdge() {
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
    // The letterbox rect all three hosts now read from here instead of
    // re-deriving inline.

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
        let fit = ViewerPointerMapping.fitRect(
            paneSize: (width: 640, height: 480), videoSize: (width: 1920, height: 1080))
        assertRect(fit, x: 0, y: 60, width: 640, height: 360)
    }

    func testFitRectPillarboxesPortraitVideoInLandscapePane() {
        let fit = ViewerPointerMapping.fitRect(
            paneSize: (width: 1280, height: 720), videoSize: (width: 1080, height: 1440))
        assertRect(fit, x: 370, y: 0, width: 540, height: 720)
    }

    /// No one-pixel sliver from a strict-inequality asymmetry.
    func testFitRectExactAspectFillsThePane() {
        let fit = ViewerPointerMapping.fitRect(
            paneSize: (width: 640, height: 360), videoSize: (width: 1920, height: 1080))
        assertRect(fit, x: 0, y: 0, width: 640, height: 360)
    }

    func testFitRectDegenerateSizesReturnTheWholePane() {
        let noVideo = ViewerPointerMapping.fitRect(
            paneSize: (width: 640, height: 360), videoSize: (width: 0, height: 1080))
        assertRect(noVideo, x: 0, y: 0, width: 640, height: 360)
        let noPane = ViewerPointerMapping.fitRect(
            paneSize: (width: 0, height: 0), videoSize: (width: 1920, height: 1080))
        assertRect(noPane, x: 0, y: 0, width: 0, height: 0)
    }

    /// A pointer at the fit rect's corners must normalize to exactly (0,0)
    /// and (1,1).
    func testFitRectAgreesWithNormalize() {
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

    /// The WinUI viewer composites strokes into the decoded frame; `render`'s
    /// clear would erase the video.
    func testDrawKeepsWhatIsAlreadyThere() {
        var pixels = opaqueSurface()
        let stroke = Annotation(
            id: UUID(), tool: .line,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.4, y: 0.5)],
            color: Annotation.RGBA(r: 0, g: 0, b: 1, a: 1), width: 6)
        withSurface(&pixels) { AnnotationRasterizer.draw([stroke], into: $0) }

        let corner = (height - 1) * width * 4
        XCTAssertEqual(pixels[corner + 2], 200, "background must survive a composite")
        XCTAssertEqual(pixels[corner + 3], 255)
    }

    func testRenderStillClears() {
        var pixels = opaqueSurface()
        withSurface(&pixels) { AnnotationRasterizer.render([], into: $0) }
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 }, "render must clear to transparent")
    }

    /// Source-over onto an opaque destination must leave alpha at 255, or
    /// the WriteableBitmap would show a translucent hole that reads as a
    /// rendering style rather than a bug.
    func testCompositedStrokeStaysOpaque() {
        var pixels = opaqueSurface()
        let stroke = Annotation(
            id: UUID(), tool: .line,
            points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)],
            // Width 300 quoted against `referenceShortEdge` (1000px) is
            // ~9.6px on this 32px surface — thick enough to fully cover
            // the sampled centre pixel.
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
        let store = AnnotationStore()
        store.mode = .drawing(.pen)
        store.beginStroke(at: CGPoint(x: 0.1, y: 0.1))
        store.extendStroke(to: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(store.visibleAnnotations.count, 1)
        XCTAssertEqual(store.visibleAnnotations.first?.points.count, 2)
    }

    /// Fixed rather than fresh per read, so a renderer diffing by id sees
    /// one stroke growing rather than a new one every frame.
    func testLiveStrokeKeepsOneIdentityAcrossTheDrag() {
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
        XCTAssertEqual(store.visibleAnnotations.count, 1)
    }

    func testRelayedStrokesAreVisibleToo() {
        let store = AnnotationStore()
        let remote = Annotation(
            id: UUID(), tool: .arrow,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
            color: Annotation.RGBA.palette[1], width: 3)
        store.apply(.add(remote))
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [remote.id])
    }
}
