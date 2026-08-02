import Foundation
import XCTest

@testable import X11CaptureKit

/// Two halves, split by what CI can actually run.
///
/// The colour-conversion tests need no X server and always run: they pin the
/// limited-range BT.709 contract by inverting the *viewer's own* shader math
/// and checking the pixels come back. Getting that convention wrong doesn't
/// fail loudly in production — every frame is just washed out or crushed — so
/// it's worth an exact test rather than a smoke test.
///
/// The capture tests need a display and self-skip without one. Under Xvfb they
/// run headlessly, which is the whole reason the X11 backend exists ahead of
/// the ScreenCast portal.
final class CaptureTests: XCTestCase {

    // MARK: - Colour conversion (no X server needed)

    /// The inverse of `Apps/linux/Sources/CGtkVideo/cgtkvideo.c`'s fragment
    /// shader, transcribed. If this and the shader ever disagree, the picture
    /// is wrong on the wire in a way no other test would catch.
    private func shaderRGB(y: UInt8, u: UInt8, v: UInt8) -> (r: Double, g: Double, b: Double) {
        let yy = (Double(y) / 255.0 - 16.0 / 255.0) * (255.0 / 219.0)
        let uu = (Double(u) / 255.0 - 0.5) * (255.0 / 224.0)
        let vv = (Double(v) / 255.0 - 0.5) * (255.0 / 224.0)
        return (
            min(max(yy + 1.5748 * vv, 0), 1),
            min(max(yy - 0.1873 * uu - 0.4681 * vv, 0), 1),
            min(max(yy + 1.8556 * uu, 0), 1)
        )
    }

    private func solid(_ b: UInt8, _ g: UInt8, _ r: UInt8, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: out.count, by: 4) {
            out[i] = b
            out[i + 1] = g
            out[i + 2] = r
            out[i + 3] = 255
        }
        return out
    }

    func testWhiteAndBlackHitStudioSwing() {
        let w = 8
        let h = 8
        let white = X11ScreenCapture.convertBGRA(
            solid(255, 255, 255, width: w, height: h), stride: w * 4, width: w, height: h)
        XCTAssertEqual(white.y[0], 235, "white luma must be the studio-swing ceiling")
        XCTAssertEqual(white.u[0], 128)
        XCTAssertEqual(white.v[0], 128)

        let black = X11ScreenCapture.convertBGRA(
            solid(0, 0, 0, width: w, height: h), stride: w * 4, width: w, height: h)
        XCTAssertEqual(black.y[0], 16, "black luma must be the studio-swing floor")
        XCTAssertEqual(black.u[0], 128)
        XCTAssertEqual(black.v[0], 128)
    }

    /// Primaries survive the round trip through the viewer's shader math.
    /// Tolerance is generous (5/255) because 4:2:0 chroma and 8-bit fixed-point
    /// both lose a little; what's being asserted is that the *convention*
    /// matches, not that the pipeline is lossless.
    func testPrimariesRoundTripThroughTheViewerShader() {
        let cases: [(name: String, b: UInt8, g: UInt8, r: UInt8)] = [
            ("red", 0, 0, 255),
            ("green", 0, 255, 0),
            ("blue", 255, 0, 0),
            ("mid grey", 128, 128, 128),
            ("orange", 0, 128, 255)
        ]
        let w = 8
        let h = 8
        for c in cases {
            let p = X11ScreenCapture.convertBGRA(
                solid(c.b, c.g, c.r, width: w, height: h), stride: w * 4, width: w, height: h)
            let rgb = shaderRGB(y: p.y[0], u: p.u[0], v: p.v[0])
            XCTAssertEqual(rgb.r, Double(c.r) / 255, accuracy: 5.0 / 255, "\(c.name) red")
            XCTAssertEqual(rgb.g, Double(c.g) / 255, accuracy: 5.0 / 255, "\(c.name) green")
            XCTAssertEqual(rgb.b, Double(c.b) / 255, accuracy: 5.0 / 255, "\(c.name) blue")
        }
    }

    /// Plane sizes are the encoder's contract: luma `w×h`, chroma
    /// `(w/2)×(h/2)`, tightly packed with no row padding.
    func testPlaneGeometry() {
        let p = X11ScreenCapture.convertBGRA(
            solid(10, 20, 30, width: 16, height: 10), stride: 16 * 4, width: 16, height: 10)
        XCTAssertEqual(p.y.count, 16 * 10)
        XCTAssertEqual(p.u.count, 8 * 5)
        XCTAssertEqual(p.v.count, 8 * 5)
    }

    /// The capture buffer's row stride exceeds the region being converted
    /// whenever output is cropped to even dimensions — so the converter must
    /// honour `stride`, not assume `width * 4`.
    func testStrideLargerThanWidthIsHonoured() {
        let srcW = 16
        let outW = 8
        let h = 4
        var bgra = solid(0, 0, 0, width: srcW, height: h)
        // Paint the left half (which we convert) white, right half black. If
        // stride were ignored, rows would smear and luma wouldn't be uniform.
        for row in 0..<h {
            for col in 0..<outW {
                let i = (row * srcW + col) * 4
                bgra[i] = 255
                bgra[i + 1] = 255
                bgra[i + 2] = 255
            }
        }
        let p = X11ScreenCapture.convertBGRA(bgra, stride: srcW * 4, width: outW, height: h)
        XCTAssertTrue(p.y.allSatisfy { $0 == 235 }, "stride was not honoured — rows smeared")
    }

    // MARK: - Live capture (needs a display; Xvfb in CI)

    private func openCapture() throws -> X11ScreenCapture {
        guard ProcessInfo.processInfo.environment["DISPLAY"] != nil else {
            throw XCTSkip("no DISPLAY — run under Xvfb for the capture leg")
        }
        do {
            return try X11ScreenCapture()
        } catch {
            throw XCTSkip("cannot open X display: \(error)")
        }
    }

    func testCaptureReportsEvenGeometry() throws {
        let cap = try openCapture()
        XCTAssertGreaterThan(cap.screenWidth, 0)
        XCTAssertGreaterThan(cap.screenHeight, 0)
        XCTAssertEqual(cap.captureWidth % 2, 0)
        XCTAssertEqual(cap.captureHeight % 2, 0)
        XCTAssertLessThanOrEqual(cap.captureWidth, cap.screenWidth)
        XCTAssertLessThanOrEqual(cap.captureHeight, cap.screenHeight)
    }

    func testGrabProducesFullPlanes() throws {
        let cap = try openCapture()
        var planes = cap.makePlanes()
        try cap.grab(into: &planes)
        XCTAssertEqual(planes.y.count, cap.captureWidth * cap.captureHeight)
        XCTAssertEqual(planes.u.count, (cap.captureWidth / 2) * (cap.captureHeight / 2))
        XCTAssertEqual(planes.v.count, planes.u.count)
        // A bare Xvfb root is uniform, so don't assert on content — assert the
        // luma is in studio swing, which proves the conversion ran over every
        // pixel rather than leaving the buffer at its initial zeroes.
        XCTAssertTrue(
            planes.y.allSatisfy { $0 >= 16 && $0 <= 235 },
            "luma outside studio swing — conversion did not cover the frame")
    }

    /// Grabbing repeatedly must be stable: the SHM segment is reused across
    /// frames, and a mistake there shows up as a second grab failing or
    /// returning garbage rather than as a first-frame bug.
    func testRepeatedGrabsAreStable() throws {
        let cap = try openCapture()
        var planes = cap.makePlanes()
        for _ in 0..<10 {
            try cap.grab(into: &planes)
        }
        XCTAssertTrue(planes.y.allSatisfy { $0 >= 16 && $0 <= 235 })
    }
}
