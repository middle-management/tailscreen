import Foundation
import SendInputKit
import TailscreenProtocol
import TailscreenSharer

/// `SendInputInjector` as the sharer's `InputInjecting` backend.
///
/// A thin adapter rather than an empty extension (unlike macOS): the seam
/// resolves geometry from a `PickerSelection`, but a WGC
/// `GraphicsCaptureItem` carries no HMONITOR/HWND to ask — only whoever built
/// the item knows the region, so this adapter takes it as a closure.
///
/// When no region is available, this must not guess a click's location — the
/// HOST decides whether to supply an injector at all, and the server
/// withholds `ScreenShareCaps.remoteControl` when it does not.
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

    /// The selection is ignored (see type comment); its arrival is still the
    /// signal to re-read the region for a mid-share source change.
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
