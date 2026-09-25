import Foundation
import TailscreenProtocol
import X11CaptureKit

/// Proves the capture outline reaches the screen, and that it leaves the
/// middle of the screen alone.
///
/// `CaptureOutlineTests` covers the arithmetic on a buffer; what no unit test
/// can reach is whether those pixels are actually composited onto a real X11
/// desktop, at the right place. In particular, an outline that filled the
/// whole overlay would paint a solid rectangle over the shared desktop with no
/// error anywhere — reading the CENTRE back through the sharer's own capture
/// path is how that gets caught.
enum OutlineSelfTest {
    static let passMarker = "CGTKOUTLINE_SELFTEST result=PASS"

    /// The chroma margins a genuine orange border has to clear: high Cr and
    /// low Cb together, so a bright patch of anything else can't pass by
    /// raising only one.
    static let minCrMargin = 8
    static let minCbMargin = 4

    static func run() {
        let capture: X11ScreenCapture
        do {
            capture = try X11ScreenCapture()
        } catch {
            finish(false, "could not open the X display for capture: \(error)")
            return
        }
        let width = capture.captureWidth
        let height = capture.captureHeight
        guard let overlay = SharerAnnotationOverlay(width: width, height: height) else {
            finish(false, "overlay creation failed at \(width)x\(height)")
            return
        }

        // Thicker than shipping default: at half chroma resolution, a thin
        // border would make this a test of the chroma sampler, not of arrival.
        overlay.setShowsOutlineForTesting(true, thickness: 24)

        // Let GTK map the window and the compositor paint it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            check(capture: capture, overlay: overlay, width: width, height: height)
        }
    }

    private static func check(
        capture: X11ScreenCapture, overlay: SharerAnnotationOverlay,
        width: Int, height: Int
    ) {
        var planes = capture.makePlanes()
        do {
            try capture.grab(into: &planes)
        } catch {
            finish(false, "screen grab failed: \(error)")
            return
        }

        let chromaWidth = width / 2
        let chromaHeight = height / 2
        func chroma(_ plane: [UInt8], atX x: Double, y: Double) -> Int {
            let px = min(max(Int(x * Double(width)) / 2, 0), chromaWidth - 1)
            let py = min(max(Int(y * Double(height)) / 2, 0), chromaHeight - 1)
            return Int(plane[py * chromaWidth + px])
        }

        // Left edge, halfway down; dead centre as the control.
        let edgeV = chroma(planes.v, atX: 0.004, y: 0.5)
        let edgeU = chroma(planes.u, atX: 0.004, y: 0.5)
        let centreV = chroma(planes.v, atX: 0.5, y: 0.5)
        let centreU = chroma(planes.u, atX: 0.5, y: 0.5)

        let bordered = (edgeV - centreV) >= minCrMargin && (centreU - edgeU) >= minCbMargin
        // Interior must be UNTOUCHED (neutral desktop sits at 128/128), not
        // merely less orange — else the border could have bled inward.
        let interiorClean = abs(centreV - 128) < minCrMargin && abs(centreU - 128) < minCbMargin

        let detail =
            "edge V=\(edgeV) U=\(edgeU), centre V=\(centreV) U=\(centreU) "
            + "(need ΔV≥\(minCrMargin), ΔU≥\(minCbMargin), centre within \(minCrMargin) of 128)"
        overlay.setShowsOutlineForTesting(false, thickness: nil)
        if !bordered {
            finish(false, "no outline at the edge — \(detail)")
        } else if !interiorClean {
            finish(false, "the outline covered the interior — \(detail)")
        } else {
            finish(true, detail)
        }
    }

    private static func finish(_ passed: Bool, _ detail: String) {
        let line =
            passed ? "\(passMarker) \(detail)" : "CGTKOUTLINE_SELFTEST result=FAIL \(detail)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        print(line)
        exit(passed ? 0 : 1)
    }
}
