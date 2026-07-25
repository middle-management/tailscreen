import Foundation

/// macOS's implementations of the two seams the portable sharer data plane
/// (`TailscreenSharer`) runs on.
///
/// `TailscaleScreenShareServer` lives in `Packages/TailscreenKit` and knows
/// nothing about ScreenCaptureKit, VideoToolbox, or `CGEvent`. Everything
/// platform-specific about being a *sharer* on this OS is behind these two
/// conformances plus the convenience initializer that wires them together.

// MARK: - Capture + encode

/// The capture-helper subprocess wrapper satisfies `CaptureEncoding` as-is:
/// its callback surface and command set were already the capture-helper wire
/// (`CaptureHelperWire.OutType` / `InType`), which is exactly what the
/// protocol was shaped from. No adapter code — just the declaration.
extension HelperScreenCapture: CaptureEncoding {}

// MARK: - Remote-control injection

/// The `CGEvent` injector satisfies `InputInjecting` as-is. Note this runs in
/// the **main** process, not a helper: injection needs Accessibility TCC, not
/// Screen Recording, so there's no `replayd` coupling to isolate.
extension RemoteControlInjector: InputInjecting {}

// MARK: - Wiring

extension TailscaleScreenShareServer {
    /// The macOS sharer: capture through a fresh `--capture-helper` child per
    /// share (process death is the only thing that reliably releases
    /// `replayd`'s per-bundle slot, which is why this is a factory rather than
    /// one long-lived object), and input injection through `CGEvent`.
    ///
    /// Supplying the injector is what makes this build advertise
    /// `ScreenShareCaps.remoteControl`, so viewers offer Request Control — the
    /// portable server withholds that bit when a host passes no injector.
    convenience init() {
        self.init(
            port: NetworkConfig.tailscreenPort,
            captureFactory: { HelperScreenCapture() },
            inputInjector: RemoteControlInjector()
        )
    }
}
