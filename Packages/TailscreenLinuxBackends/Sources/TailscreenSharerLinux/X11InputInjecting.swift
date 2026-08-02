import Foundation
import TailscreenProtocol
import TailscreenSharer
import X11CaptureKit
import XTestInjectKit

/// `XTestInjector` as the sharer's `InputInjecting` backend.
///
/// A thin adapter rather than an empty extension — which is what macOS gets
/// away with in `ScreenShareBackends.swift` — for two reasons. The first is
/// the same one `WindowsInputInjector` gives: the seam is written around
/// `PickerSelection`, and answering "where is the shared content" from one is
/// the host's job, not the injector's. The second is mechanical: a retroactive
/// conformance of an imported type to an imported protocol is a warning Swift
/// raises on purpose, since XTestInjectKit could add the conformance itself
/// later and the two would collide.
///
/// **What the region actually is.** Not the root window — the rectangle the
/// *encoder* sends. `X11ScreenCapture` rounds both dimensions down to even for
/// I420, so on a display with an odd dimension the encoded frame is a pixel
/// smaller than the screen, and a viewer's normalized coordinates are relative
/// to the frame it sees. One pixel of drift is invisible until someone aims at
/// the last row, which is exactly where the taskbar lives.
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

    /// Whether this host can inject at all: the display opens **and** carries
    /// the XTEST extension.
    ///
    /// The second half is why this is not hardcoded true. XTEST is optional,
    /// some remote and kiosk X servers ship without it, and without the check
    /// the sharer would grant control to a viewer whose every click silently
    /// vanishes — the exact failure the capability bits exist to prevent.
    public func isTrusted() -> Bool { injector.isTrusted() }

    /// Nothing to prompt for on X11 — any client that can open the display can
    /// synthesize input, which is a property of the protocol rather than
    /// something this app decides. Returns `isTrusted()` so callers written
    /// against the macOS shape behave sensibly.
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

    /// Read live rather than cached: a session can change resolution mid-share
    /// (RandR, a projector plugged in), and a stale rect silently puts every
    /// click in the wrong place. Called at share start and on each source
    /// change, never per event, so the cost of opening a probe connection is
    /// irrelevant.
    ///
    /// Only a `.display` selection resolves today, because root capture is all
    /// `X11CaptureEncoder` does; anything else yields nil, which leaves the
    /// gate closed rather than aiming clicks at a rectangle nobody chose. When
    /// the ScreenCast portal lands (Phase 3.3) and window shares become real,
    /// this is the one function that changes.
    private func region(for selection: PickerSelection?) -> XTestInjector.Region? {
        guard let selection, selection.kind == .display else { return nil }
        guard let capture = try? X11ScreenCapture(display: display),
            capture.captureWidth > 0, capture.captureHeight > 0
        else {
            // Falling back to the root is deliberate rather than returning
            // nil: the capture is already running (this is a live share), so
            // failing to open a *second* connection is a resource hiccup, not
            // a sign the geometry is unknown. An at-most-one-pixel error beats
            // silently refusing every click.
            return injector.rootRegion()
        }
        return XTestInjector.Region(
            x: 0, y: 0, width: capture.captureWidth, height: capture.captureHeight)
    }
}
