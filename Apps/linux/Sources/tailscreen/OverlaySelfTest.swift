import Foundation
import TailscreenProtocol
import X11CaptureKit

/// `tailscreen --overlay-self-test`: prove the sharer's annotation overlay
/// actually puts pixels on the screen.
///
/// Counterpart of `--render-self-test`: a window that never maps, is ignored
/// by the compositor, is mis-positioned, or has a wrong channel order all
/// produce a working share with invisible annotations and no error. So this
/// draws a known stroke and reads the screen back through the same X11
/// capture path the sharer encodes from — a PASS means it reached the real
/// framebuffer, not just that GTK accepted the calls.
///
/// Runs under Xvfb + a compositing manager in CI (`linux-app` job); without a
/// compositor the overlay deliberately refuses to exist, and this would test
/// that refusal instead of the drawing.
enum OverlaySelfTest {
    /// CI greps for this, so an early exit that skipped the comparison can't
    /// pass by exiting 0.
    static let passMarker = "CGTKOVERLAY_SELFTEST result=PASS"

    /// Not full width — a stroke edge-to-edge would still look right even if
    /// the overlay had the wrong horizontal origin.
    private static let strokeY = 0.5
    private static let strokeX0 = 0.25
    private static let strokeX1 = 0.75

    /// Margins (not absolute values) between on-stroke and off-stroke chroma,
    /// since what sits behind the overlay's transparent parts isn't ours to
    /// control. The two differ because BT.709 limited-range red moves Cr by
    /// ~112 but Cb by only ~26 — a symmetric threshold would be loose on one
    /// or flaky on the other.
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

        // Thick: the assertion samples a single pixel, and an antialiased
        // hairline would read as washed-out pink.
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

        // Repaint + compositing are both async; returning here is what lets
        // them happen before the scheduled check runs.
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

        // I420 chroma planes are half resolution; capture dimensions are even
        // by construction (`captureWidth` masks the low bit off), so this
        // halving is exact.
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        func chroma(_ plane: [UInt8], atX x: Double, y: Double) -> Int {
            let px = min(max(Int(x * Double(width)) / 2, 0), chromaWidth - 1)
            let py = min(max(Int(y * Double(height)) / 2, 0), chromaHeight - 1)
            return Int(plane[py * chromaWidth + px])
        }

        // On the stroke, and a quarter-screen higher (same column), so a
        // vertically misplaced overlay fails rather than sampling a stroke
        // that moved with it.
        let midX = (strokeX0 + strokeX1) / 2
        let onV = chroma(planes.v, atX: midX, y: strokeY)
        let offV = chroma(planes.v, atX: midX, y: strokeY - 0.25)
        let onU = chroma(planes.u, atX: midX, y: strokeY)
        let offU = chroma(planes.u, atX: midX, y: strokeY - 0.25)

        // Requiring both V and U to move excludes a bright patch of anything
        // else showing through the overlay.
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
        // 3 for a real failure, matching the render self-test's convention
        // (so timeout/124 and a crash stay distinguishable).
        exit(passed ? 0 : 3)
    }
}
