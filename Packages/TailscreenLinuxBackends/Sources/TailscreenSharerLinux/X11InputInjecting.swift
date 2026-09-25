import Foundation
import TailscreenProtocol
import TailscreenSharer
import X11CaptureKit
import XTestInjectKit

/// `XTestInjector` as the sharer's `InputInjecting` backend.
///
/// A thin adapter rather than an empty extension (unlike macOS): the seam
/// resolves "where is the shared content" from a `PickerSelection`, which is
/// the host's job, and a retroactive conformance of an imported type to an
/// imported protocol would collide if XTestInjectKit later added its own.
///
/// The injection region is not the root window but the rectangle the
/// *encoder* sends: `X11ScreenCapture` rounds dimensions down to even for
/// I420, so on an odd-sized display the encoded frame is a pixel smaller
/// than the screen — drift invisible until someone aims at the last row
/// (where the taskbar lives).
public final class X11InputInjector: InputInjecting, @unchecked Sendable {
    private let injector: XTestInjector
    private let display: String?

    /// - Parameter display: the X display to inject into, and to measure the
    ///   capture geometry from. Nil means `$DISPLAY`, which is what the app
    ///   passes; the headless sharer names it.
    public init(display: String? = nil, injector: XTestInjector? = nil) {
        self.display = display
        self.injector = injector ?? XTestInjector(displayName: display)
    }

    /// Whether this host can inject at all: the display opens AND carries the
    /// XTEST extension (some remote/kiosk X servers ship without it — without
    /// this check the sharer would grant control that silently vanishes).
    public func isTrusted() -> Bool { injector.isTrusted() }

    /// Nothing to prompt for on X11 — any client that can open the display
    /// can synthesize input. Returns `isTrusted()` for macOS-shaped callers.
    @discardableResult
    public func promptForAccess() -> Bool { injector.promptForAccess() }

    public func setSelection(_ selection: PickerSelection?) {
        injector.setRegion(region(for: selection))
    }

    public func activate(selection: PickerSelection?) {
        injector.activate(region: region(for: selection))
    }

    public func deactivate() {
        injector.deactivate()
    }

    public func apply(_ event: InputEvent) {
        injector.apply(event)
    }

    /// Read live rather than cached: resolution can change mid-share (RandR,
    /// a projector), and a stale rect silently misplaces clicks. Called at
    /// share start and on source change only.
    ///
    /// Only `.display` resolves today (root capture is all `X11CaptureEncoder`
    /// does); anything else yields nil, closing the gate rather than aiming
    /// at a rectangle nobody chose.
    private func region(for selection: PickerSelection?) -> XTestInjector.Region? {
        guard let selection, selection.kind == .display else { return nil }
        guard let capture = try? X11ScreenCapture(display: display),
            capture.captureWidth > 0, capture.captureHeight > 0
        else {
            // Falls back to root rather than nil: capture is already running,
            // so a second-connection failure is a hiccup, not unknown
            // geometry. An at-most-one-pixel error beats refusing every click.
            return injector.rootRegion()
        }
        return XTestInjector.Region(
            x: 0, y: 0, width: capture.captureWidth, height: capture.captureHeight)
    }
}
