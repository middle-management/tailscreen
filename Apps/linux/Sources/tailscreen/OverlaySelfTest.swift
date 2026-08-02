import Foundation
import TailscreenProtocol
import X11CaptureKit

/// `tailscreen --overlay-self-test`: prove the sharer's annotation overlay
/// actually puts pixels on the screen.
///
/// The counterpart of `--render-self-test`, and it exists for the same reason:
/// everything either overlay path could get wrong is invisible. A window that
/// never maps, one the compositor ignores, one placed at the wrong origin, one
/// whose bytes cairo reads as the wrong channel order — all four produce a
/// share that works perfectly and annotations nobody can see, with no error
/// anywhere. So instead of trusting the window, this draws a known stroke and
/// reads the screen back through the same X11 capture path the sharer encodes
/// from.
///
/// That last part is what makes it worth the code: the capture is the sharer's
/// real eye on the screen, so a PASS means the overlay reached the actual
/// framebuffer — not merely that GTK accepted the calls.
///
/// Runs under Xvfb + a compositing manager in CI (see the `linux-app` job).
/// The compositor is not optional set dressing: without one the overlay
/// refuses to exist at all, deliberately, and this test would be checking the
/// refusal rather than the drawing.
enum OverlaySelfTest {
    /// Printed on the happy path; the CI step greps for it, so a "graceful"
    /// early exit that never ran a comparison cannot pass by exiting 0.
    static let passMarker = "CGTKOVERLAY_SELFTEST result=PASS"

    /// Where the stroke goes, in normalized capture coordinates. Horizontal
    /// across the middle, and deliberately not full width — a stroke that ran
    /// edge to edge would still look right if the overlay were placed at the
    /// wrong horizontal origin.
    private static let strokeY = 0.5
    private static let strokeX0 = 0.25
    private static let strokeX1 = 0.75

    /// How far apart the on-stroke and off-stroke chroma readings must be for
    /// this to count as "the stroke is there, in red".
    ///
    /// Margins rather than absolute values, because what sits *behind* the
    /// transparent parts of the overlay is not ours to control — under Xvfb it
    /// is the app's own hub window, on a desktop it is whatever the user has
    /// open. Contrast against a control point is the assertion that holds in
    /// both.
    ///
    /// The two differ by a lot because the colour space says they must: in
    /// BT.709 limited range, pure red moves Cr by ~112 and Cb by only ~26. A
    /// symmetric threshold would either be trivially loose on V or sit two
    /// counts under the real U value — which is a test that goes red the first
    /// time antialiasing shifts a sample, and is then "fixed" by loosening the
    /// number, which is how a threshold stops meaning anything.
    private static let minCrMargin = 60
    private static let minCbMargin = 12

    static func run() {
        guard SharerAnnotationOverlay.isSupported else {
            finish(false, "no compositing manager — the overlay refuses to exist here")
            return
        }
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

        // Pure red at full alpha, and thick. Thickness matters more than it
        // looks: the assertion samples a single pixel, and a hairline that the
        // rasterizer antialiases to 40 % coverage would read as a washed-out
        // pink that no threshold could separate from a rendering opinion.
        let stroke = Annotation(
            id: UUID(),
            tool: .line,
            points: [
                CGPoint(x: strokeX0, y: strokeY),
                CGPoint(x: strokeX1, y: strokeY)
            ],
            color: Annotation.RGBA(r: 1, g: 0, b: 0, a: 1),
            width: 40)
        overlay.apply(.add(stroke))

        // The overlay marshals its repaint onto the GTK main loop, and the X
        // server then has to composite it. Both are asynchronous, so the check
        // is scheduled rather than run inline — this function is itself called
        // from the running loop, so returning is what lets the paint happen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
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

        // The chroma planes are half resolution in both axes (I420), so a
        // point in capture pixels indexes them at half the coordinates. Both
        // capture dimensions are even by construction (`captureWidth` masks the
        // low bit off), so the halving is exact.
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        func chroma(_ plane: [UInt8], atX x: Double, y: Double) -> Int {
            let px = min(max(Int(x * Double(width)) / 2, 0), chromaWidth - 1)
            let py = min(max(Int(y * Double(height)) / 2, 0), chromaHeight - 1)
            return Int(plane[py * chromaWidth + px])
        }

        // On the stroke, and well away from it — same column, a quarter of the
        // screen higher, so a vertically misplaced overlay fails here rather
        // than passing on a stroke that happens to be somewhere else.
        let midX = (strokeX0 + strokeX1) / 2
        let onV = chroma(planes.v, atX: midX, y: strokeY)
        let offV = chroma(planes.v, atX: midX, y: strokeY - 0.25)
        let onU = chroma(planes.u, atX: midX, y: strokeY)
        let offU = chroma(planes.u, atX: midX, y: strokeY - 0.25)

        // Red is high V (Cr) and low U (Cb). Requiring BOTH excludes a bright
        // patch of anything — a white window behind a hole in the overlay
        // would raise neither.
        let redder = (onV - offV) >= minCrMargin
        let lessBlue = (offU - onU) >= minCbMargin
        let detail =
            "V on=\(onV) off=\(offV) (Δ\(onV - offV), need ≥\(minCrMargin)), "
            + "U on=\(onU) off=\(offU) (Δ\(offU - onU), need ≥\(minCbMargin))"
        overlay.clear()
        finish(redder && lessBlue, detail)
    }

    private static func finish(_ passed: Bool, _ detail: String) {
        let line =
            passed
            ? "\(passMarker) \(detail)"
            : "CGTKOVERLAY_SELFTEST result=FAIL \(detail)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        print(line)
        // Same exit convention as the render self-test: 3 for a real failure,
        // so a timeout (124) and a crash stay distinguishable from bad pixels.
        exit(passed ? 0 : 3)
    }
}
