import Foundation

// macOS's implementations of the two seams the portable sharer data plane
// (`TailscreenSharer`) runs on; `TailscaleScreenShareServer` itself knows
// nothing about ScreenCaptureKit, VideoToolbox, or `CGEvent`.

// MARK: - Capture + encode

/// Already matches `CaptureEncoding`: the capture-helper wire
/// (`CaptureHelperWire.OutType`/`InType`) is what the protocol was shaped from.
extension HelperScreenCapture: CaptureEncoding {}

// MARK: - Remote-control injection

/// Runs in the **main** process, not a helper: injection needs Accessibility
/// TCC, not Screen Recording, so there's no `replayd` coupling to isolate.
extension RemoteControlInjector: InputInjecting {}

// MARK: - Wiring

extension TailscaleScreenShareServer {
    /// macOS sharer: a fresh `--capture-helper` child per share (process death
    /// is the only reliable way to release `replayd`'s per-bundle slot, hence
    /// a factory rather than one long-lived object) plus `CGEvent` injection.
    ///
    /// Passing the injector/`rendersAnnotations: true`/`promptsForLinks: true`
    /// is what makes the portable server advertise
    /// `ScreenShareCaps.remoteControl`/`.annotations`/`.openLink` — the sole
    /// place this build states its capabilities.
    convenience init() {
        self.init(
            port: NetworkConfig.tailscreenPort,
            captureFactory: { HelperScreenCapture() },
            inputInjector: RemoteControlInjector(),
            rendersAnnotations: true,
            promptsForLinks: true
        )
    }
}
