import Foundation
import SendInputKit
import TailscreenProtocol
import TailscreenSharer

/// `SendInputInjector` as the sharer's `InputInjecting` backend.
///
/// A thin adapter rather than an empty extension — which is what macOS gets
/// away with in `ScreenShareBackends.swift` — because the protocol is written
/// around `PickerSelection` and Windows cannot answer the geometry question
/// from one.
///
/// **The gap, stated plainly.** The seam's `activate(selection:)` exists so an
/// injector can look up where the shared content lives: on macOS a
/// `PickerSelection` carries a `CGDirectDisplayID` or a `CGWindowID`, and
/// `RemoteControlMapping` resolves the rect from it. A WGC
/// `GraphicsCaptureItem` carries neither — it is an opaque object with a size
/// and a display name, and no HMONITOR or HWND to ask. So the region has to
/// come from whoever built the item, and this adapter takes it as a closure.
///
/// When no region is available, normalized coordinates cannot be mapped, and
/// this must not guess. A click landing somewhere the viewer did not aim it is
/// worse than a click that does not happen — so the HOST decides whether to
/// supply an injector at all, and the server withholds
/// `ScreenShareCaps.remoteControl` when it does not, leaving viewers to hide
/// Request Control rather than send requests into a void.
public final class WindowsInputInjector: InputInjecting, @unchecked Sendable {
    private let injector: SendInputInjector
    private let regionProvider: @Sendable () -> SendInputInjector.Region?

    /// - Parameter regionProvider: where the shared content is on screen, in
    ///   screen pixels. Called at activation and on a source change, so a
    ///   moved or resized window is picked up. Return nil when unknown — the
    ///   injector then drops events rather than mapping them wrongly.
    public init(
        injector: SendInputInjector = SendInputInjector(),
        regionProvider: @escaping @Sendable () -> SendInputInjector.Region?
    ) {
        self.injector = injector
        self.regionProvider = regionProvider
    }

    public func isTrusted() -> Bool { injector.isTrusted() }

    @discardableResult
    public func promptForAccess() -> Bool { injector.promptForAccess() }

    /// The selection is ignored, deliberately: see the type comment. Its
    /// arrival is still the signal to re-read the region, which is what a
    /// mid-share source change needs.
    public func setSelection(_ selection: PickerSelection?) {
        injector.setRegion(selection == nil ? nil : regionProvider())
    }

    public func activate(selection: PickerSelection?) {
        injector.activate(region: regionProvider())
    }

    public func deactivate() {
        injector.deactivate()
    }

    public func apply(_ event: InputEvent) {
        injector.apply(event)
    }
}
