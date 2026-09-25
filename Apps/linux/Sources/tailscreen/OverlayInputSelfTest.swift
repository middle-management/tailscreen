import Foundation
import TailscreenProtocol
import XTestInjectKit

/// `tailscreen --overlay-input-self-test`: prove the sharer can draw on their
/// own screen, and — more importantly — prove they can stop.
///
/// Separate from `--overlay-self-test` (pixels reaching the framebuffer).
/// This checks the opposite: whether the overlay takes the pointer back from
/// the desktop when a tool is armed, and releases it on Escape. Both failure
/// modes are silent in production: an input region that never flips just
/// looks like a broken tool, while Escape never arriving locks the sharer
/// behind a fullscreen click-swallowing window with no way out.
///
/// Drives real X11 input through XTEST — the same path the remote-control
/// injector uses — rather than calling the GTK signal handlers directly,
/// which would skip exactly the two things that break.
enum OverlayInputSelfTest {
    static let passMarker = "CGTKOVERLAY_INPUT_SELFTEST result=PASS"

    /// Where the synthetic drag goes, normalized. Off-centre in both axes so a
    /// transposed or mirrored coordinate mapping cannot pass by symmetry.
    private static let dragStart = CGPoint(x: 0.30, y: 0.40)
    private static let dragEnd = CGPoint(x: 0.70, y: 0.60)

    /// Not zero: rounding to whole screen pixels and back is arithmetic, not a
    /// fault, but a swapped axis or unscaled offset is well outside this.
    private static let tolerance = 0.02

    /// Escape as a USB HID usage — goes through the real HID→keysym→keycode
    /// table, since a wrong entry there is a key that silently does nothing.
    private static let escapeHID: UInt16 = 0x29

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var points: [(phase: Int, point: CGPoint)] = []
        private var escaped = false
        func note(_ phase: Int, _ point: CGPoint) {
            lock.withLock { points.append((phase, point)) }
        }
        func noteEscape() { lock.withLock { escaped = true } }
        var snapshot: ([(phase: Int, point: CGPoint)], Bool) {
            lock.withLock { (points, escaped) }
        }
    }

    static func run() {
        guard SharerAnnotationOverlay.isSupported else {
            finish(false, "no compositing manager — the overlay refuses to exist here")
            return
        }
        // `XTestInjector` rather than the sharer's `X11InputInjector` wrapper:
        // this wants the root region and a raw injection target, not the
        // wrapper's `PickerSelection` vocabulary.
        let injector = XTestInjector()
        guard injector.isTrusted() else {
            finish(false, "this X server has no XTEST extension, so nothing can be injected")
            return
        }
        guard let region = injector.rootRegion() else {
            finish(false, "could not read the root window geometry")
            return
        }
        let width = Int(region.width)
        let height = Int(region.height)
        guard let overlay = SharerAnnotationOverlay(width: width, height: height) else {
            finish(false, "overlay creation failed at \(width)x\(height)")
            return
        }

        let recorder = Recorder()
        overlay.onPointer = { phase, point in recorder.note(phase, point) }
        overlay.onEscape = { recorder.noteEscape() }

        // Map first — arming a never-shown window would fail for an unrelated
        // reason.
        overlay.apply(
            .add(
                Annotation(
                    id: UUID(), tool: .line,
                    points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)],
                    color: Annotation.RGBA(r: 1, g: 0, b: 0, a: 1), width: 8)))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard overlay.setInteractive(true) else {
                finish(false, "the overlay could not take keyboard focus, so it refused to arm")
                return
            }
            injector.activate(region: region)
            // Let the input region + focus change reach the server first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                inject(injector: injector)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    check(recorder: recorder, overlay: overlay, injector: injector)
                }
            }
        }
    }

    private static func inject(injector: XTestInjector) {
        injector.apply(
            .mouseDown(
                x: dragStart.x, y: dragStart.y, button: .left, modifiers: []))
        // A midpoint too: GtkGestureDrag reports offsets from the press, and a
        // mapping that forgot to add the start back would still land the end
        // plausibly while every intermediate point collapsed to the origin.
        injector.apply(
            .mouseMove(
                x: (dragStart.x + dragEnd.x) / 2, y: (dragStart.y + dragEnd.y) / 2))
        injector.apply(.mouseMove(x: dragEnd.x, y: dragEnd.y))
        injector.apply(
            .mouseUp(
                x: dragEnd.x, y: dragEnd.y, button: .left, modifiers: []))
        injector.apply(.keyDown(key: escapeHID, modifiers: []))
        injector.apply(.keyUp(key: escapeHID, modifiers: []))
    }

    private static func check(
        recorder: Recorder, overlay: SharerAnnotationOverlay, injector: XTestInjector
    ) {
        // Disarm before asserting anything, so a failing assertion can't leave
        // the desktop under a click-swallowing window.
        _ = overlay.setInteractive(false)
        injector.deactivate()
        overlay.clear()

        let (points, escaped) = recorder.snapshot
        guard let press = points.first(where: { $0.phase == 0 }) else {
            finish(
                false,
                "no press reached the overlay — the input region did not flip "
                    + "(\(points.count) event(s) seen)")
            return
        }
        guard let release = points.last(where: { $0.phase == 2 }) else {
            finish(false, "press arrived but no release did (\(points.count) event(s))")
            return
        }
        let moves = points.filter { $0.phase == 1 }
        let startErr = distance(press.point, dragStart)
        let endErr = distance(release.point, dragEnd)
        let detail =
            "press=(\(fmt(press.point))) want=(\(fmt(dragStart))) Δ\(fmt2(startErr)), "
            + "release=(\(fmt(release.point))) want=(\(fmt(dragEnd))) Δ\(fmt2(endErr)), "
            + "moves=\(moves.count), escape=\(escaped)"

        guard startErr <= tolerance, endErr <= tolerance else {
            finish(false, "pointer mapping is off — \(detail)")
            return
        }
        guard !moves.isEmpty else {
            finish(false, "no drag updates arrived — \(detail)")
            return
        }
        guard escaped else {
            finish(
                false,
                "Escape never reached the overlay, so an armed sharer would be "
                    + "stuck behind it — \(detail)")
            return
        }
        finish(true, detail)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func fmt(_ p: CGPoint) -> String {
        String(format: "%.3f,%.3f", p.x, p.y)
    }

    private static func fmt2(_ v: Double) -> String { String(format: "%.4f", v) }

    private static func finish(_ passed: Bool, _ detail: String) {
        let line =
            passed
            ? "\(passMarker) \(detail)"
            : "CGTKOVERLAY_INPUT_SELFTEST result=FAIL \(detail)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        print(line)
        exit(passed ? 0 : 3)
    }
}
