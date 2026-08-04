import XCTest

@testable import TailscreenProtocol

/// `ThumbnailScaler` — the sharer's own preview of what viewers can see.
///
/// Small arithmetic with three ways to be silently wrong: a channel swap that
/// renders the desktop with red and blue exchanged (which reads as a colour
/// profile problem, not a bug), a stride assumption that skews the image a
/// little further with every row, and a throttle that quietly starts running
/// per frame and costs the share its frame rate.
final class ThumbnailScalerTests: XCTestCase {

    /// A solid BGRA frame, optionally padded — every capture API in this repo
    /// pads rows, so an unpadded-only test would pass against the bug.
    private func solidFrame(
        width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8, padding: Int = 0
    ) -> (bytes: [UInt8], stride: Int) {
        let stride = width * 4 + padding
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * stride + x * 4
                bytes[pixel] = b
                bytes[pixel + 1] = g
                bytes[pixel + 2] = r
                bytes[pixel + 3] = 255
            }
        }
        return (bytes, stride)
    }

    private func scale(
        _ frame: (bytes: [UInt8], stride: Int), width: Int, height: Int, longestEdge: Int = 240
    ) -> ThumbnailScaler.Thumbnail? {
        frame.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return ThumbnailScaler.thumbnail(
                bgra: base, stride: frame.stride, width: width, height: height,
                longestEdge: longestEdge)
        }
    }

    // MARK: Channel order

    /// **BGRA in, RGBA out.** Getting this backwards renders every preview with
    /// red and blue exchanged, which on a screenshot of a desktop looks like a
    /// colour-management problem rather than a defect.
    func testBlueInputBecomesBlueOutputRatherThanRed() {
        // Pure blue in BGRA: B=255, G=0, R=0.
        let frame = solidFrame(width: 8, height: 8, b: 255, g: 0, r: 0)
        guard let thumb = scale(frame, width: 8, height: 8) else {
            return XCTFail("expected a thumbnail")
        }
        // Out is RGBA, so blue must land in the THIRD byte.
        XCTAssertEqual(thumb.rgba[0], 0, "red channel")
        XCTAssertEqual(thumb.rgba[1], 0, "green channel")
        XCTAssertEqual(thumb.rgba[2], 255, "blue channel")
        XCTAssertEqual(thumb.rgba[3], 255, "alpha must be opaque")
    }

    func testRedInputBecomesRedOutput() {
        let frame = solidFrame(width: 8, height: 8, b: 0, g: 0, r: 255)
        guard let thumb = scale(frame, width: 8, height: 8) else {
            return XCTFail("expected a thumbnail")
        }
        XCTAssertEqual(thumb.rgba[0], 255, "red channel")
        XCTAssertEqual(thumb.rgba[2], 0, "blue channel")
    }

    // MARK: Stride

    /// A padded frame must scale identically to an unpadded one. Reading at
    /// `width * 4` when the pitch is wider skews the image progressively —
    /// diagonally smeared, which is unmistakable once seen and invisible in a
    /// test that never pads.
    func testPaddedRowsScaleIdenticallyToUnpaddedOnes() {
        let unpadded = solidFrame(width: 16, height: 16, b: 10, g: 120, r: 240)
        let padded = solidFrame(width: 16, height: 16, b: 10, g: 120, r: 240, padding: 37)
        let a = scale(unpadded, width: 16, height: 16, longestEdge: 4)
        let b = scale(padded, width: 16, height: 16, longestEdge: 4)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.rgba, b?.rgba, "row padding changed the output")
    }

    func testAStrideNarrowerThanTheWidthIsRejected() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let thumb = bytes.withUnsafeMutableBufferPointer { buffer -> ThumbnailScaler.Thumbnail? in
            guard let base = buffer.baseAddress else { return nil }
            return ThumbnailScaler.thumbnail(bgra: base, stride: 4, width: 4, height: 4)
        }
        XCTAssertNil(thumb, "a stride that cannot hold one row must be refused, not read past")
    }

    // MARK: Averaging

    /// Box-average, not point-sample. A half-black half-white frame reduced to
    /// one pixel must be grey; nearest-neighbour would pick one side and
    /// report pure black or pure white.
    func testDownscalingAveragesTheBlockRatherThanPickingOnePixel() {
        let width = 8
        let height = 8
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * stride + x * 4
                let value: UInt8 = x < width / 2 ? 0 : 255
                bytes[pixel] = value
                bytes[pixel + 1] = value
                bytes[pixel + 2] = value
                bytes[pixel + 3] = 255
            }
        }
        let thumb = bytes.withUnsafeBufferPointer { buffer -> ThumbnailScaler.Thumbnail? in
            guard let base = buffer.baseAddress else { return nil }
            return ThumbnailScaler.thumbnail(
                bgra: base, stride: stride, width: width, height: height, longestEdge: 1)
        }
        guard let thumb else { return XCTFail("expected a thumbnail") }
        XCTAssertEqual(thumb.width, 1)
        XCTAssertEqual(thumb.height, 1)
        // 127 or 128 depending on integer division; the point is that it is
        // neither 0 nor 255.
        XCTAssertGreaterThan(thumb.rgba[0], 100)
        XCTAssertLessThan(thumb.rgba[0], 160)
    }

    // MARK: Fitted size

    func testAspectRatioIsPreserved() {
        let size = ThumbnailScaler.fittedSize(width: 3840, height: 2160, longestEdge: 240)
        XCTAssertEqual(size?.width, 240)
        XCTAssertEqual(size?.height, 135)
    }

    func testAPortraitFrameFitsItsHeight() {
        let size = ThumbnailScaler.fittedSize(width: 1080, height: 1920, longestEdge: 240)
        XCTAssertEqual(size?.height, 240)
        XCTAssertEqual(size?.width, 135)
    }

    /// Never enlarge: a small window blown up to the box would be a blurry
    /// magnification of something already legible.
    func testASmallFrameIsNotScaledUp() {
        let size = ThumbnailScaler.fittedSize(width: 100, height: 50, longestEdge: 240)
        XCTAssertEqual(size?.width, 100)
        XCTAssertEqual(size?.height, 50)
    }

    /// An extreme aspect ratio must not round an axis to zero — a zero-height
    /// image is a crash in whatever displays it, not a very short preview.
    func testAnExtremeAspectRatioKeepsAtLeastOnePixelPerAxis() {
        let size = ThumbnailScaler.fittedSize(width: 4000, height: 2, longestEdge: 240)
        XCTAssertEqual(size?.width, 240)
        XCTAssertGreaterThanOrEqual(size?.height ?? 0, 1)
    }

    func testDegenerateGeometryIsRejected() {
        XCTAssertNil(ThumbnailScaler.fittedSize(width: 0, height: 100))
        XCTAssertNil(ThumbnailScaler.fittedSize(width: 100, height: 0))
        XCTAssertNil(ThumbnailScaler.fittedSize(width: 100, height: 100, longestEdge: 0))
    }

    // MARK: Throttle

    func testTheFirstPreviewIsAlwaysProduced() {
        XCTAssertTrue(ThumbnailScaler.shouldCapture(lastCaptureNs: nil, nowNs: 0))
    }

    func testAPreviewIsNotProducedTwiceWithinTheInterval() {
        XCTAssertFalse(
            ThumbnailScaler.shouldCapture(
                lastCaptureNs: 1_000_000_000,
                nowNs: 1_000_000_000 + ThumbnailScaler.intervalNs - 1))
    }

    func testAPreviewIsProducedOnceTheIntervalElapses() {
        XCTAssertTrue(
            ThumbnailScaler.shouldCapture(
                lastCaptureNs: 1_000_000_000,
                nowNs: 1_000_000_000 + ThumbnailScaler.intervalNs))
    }

    /// A clock that went backwards must not read as "an enormous time has
    /// passed" and fire on every frame — which is the throttle failing in the
    /// one direction that costs the share its frame rate.
    func testABackwardsClockDoesNotFireEveryFrame() {
        XCTAssertFalse(
            ThumbnailScaler.shouldCapture(lastCaptureNs: 5_000_000_000, nowNs: 1_000_000_000))
    }
}
