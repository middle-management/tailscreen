import Foundation

/// The mac app's half of diagnostics: the facts only this platform knows, and
/// the places only this app records from. Everything portable lives in
/// `DiagnosticsHost` (TailscreenProtocol), shared with GTK/WinUI.
///
/// **Not `@MainActor`**: the recorder is written to from capture callbacks,
/// UDP receive loops and sweep timers as well as the UI, and is thread-safe
/// by its own lock. Isolating this facade would force a hop on every one of
/// those call sites, changing the timing of what's being recorded.
enum AppDiagnostics {

    /// The build and machine facts that go in a bundle's header.
    static var environment: DiagnosticsEnvironment {
        DiagnosticsEnvironment(
            platform: platform,
            appVersion: BuildInfo.marketingVersion,
            commit: BuildInfo.commit,
            configuration: BuildInfo.configuration,
            architecture: BuildInfo.architecture,
            deviceLabel: deviceLabel,
            // `BuildInfo.releaseChannel` honours the CI-stamped
            // `channelOverride`; a PR artifact's `0.0.<PR>` version string
            // alone would misread as a stable release.
            channel: BuildInfo.releaseChannel)
    }

    /// The process recorder, once `start()` has run. Optional: code that
    /// records tolerates the pre-start state rather than assuming order.
    static var recorder: DiagnosticsRecorder? { DiagnosticsCenter.shared.recorder }

    /// Create the recorder and open the session record. Called once, from
    /// `TailscreenEntry.main`.
    static func start() {
        DiagnosticsHost.start(environment: environment)
    }

    /// Turn recording on or off and persist the choice.
    static func setRecording(_ enabled: Bool) {
        DiagnosticsHost.setRecording(enabled)
    }

    // MARK: - Convenience recording

    /// Record a user action. Thin wrapper so call sites read as one line.
    static func action(
        _ name: DiagnosticEventName,
        _ fields: [String: DiagnosticValue] = [:]
    ) {
        recorder?.record(name, fields: fields)
    }

    /// Record which surface the user is looking at. The macOS app has no
    /// stored "current view", so surfaces report themselves via
    /// `View.recordsDiagnosticSurface(_:)`; call this directly for the ones
    /// SwiftUI's modifier can't reach (the viewer's `NSWindow`).
    ///
    /// Routed through `DiagnosticSurfaceTracker` so a `view.hidden` can't be
    /// recorded for a window that was never opened.
    @MainActor
    static func viewShown(_ surface: String) {
        DiagnosticSurfaceTracker.shared.shown(surface)
    }

    @MainActor
    static func viewHidden(_ surface: String) {
        DiagnosticSurfaceTracker.shared.hidden(surface)
    }

    /// Set a single window's visibility, idempotently — see
    /// `DiagnosticSurfaceTracker.setVisible`.
    @MainActor
    static func viewVisible(_ surface: String, _ isVisible: Bool) {
        DiagnosticSurfaceTracker.shared.setVisible(surface, isVisible)
    }

    /// The raw emit the tracker calls once it has decided the transition is
    /// real. Not for direct use — go through `viewShown` / `viewHidden`.
    static func emitViewShown(_ surface: String) {
        recorder?.record(.viewShown, fields: ["surface": .string(surface)])
    }

    static func emitViewHidden(_ surface: String) {
        recorder?.record(.viewHidden, fields: ["surface": .string(surface)])
    }

    /// Record a failure surfaced to the user. Hung off `AppState.presentError`
    /// (one call site for every alert-shaped error). The message isn't
    /// recorded — it's prose that varies with interpolated detail; the
    /// stable `TS-…` code is what joins a bundle to the error registry.
    static func fault(code: String, title: String) {
        recorder?.record(
            .faultSurfaced,
            fields: ["code": .string(code), "title": .string(title)])
    }

    // MARK: - Export

    /// `~/Library/Logs/Tailscreen/` — where Console.app looks, and where
    /// disposable files a user is about to send someone belong (not
    /// Application Support).
    static var exportDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return
            (base ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .appendingPathComponent("Logs/Tailscreen", isDirectory: true)
    }

    /// Write the current recording out and return where it went.
    @discardableResult
    static func export() throws -> URL {
        try DiagnosticsHost.export(to: exportDirectory)
    }

    /// Merge bundles somebody sent with this Mac's own recording, and write
    /// the readable timeline beside the exports. The merge rules themselves
    /// live in `DiagnosticsHost`, not here — not mac-specific.
    @discardableResult
    static func merge(with urls: [URL]) throws -> URL {
        try DiagnosticsHost.merge(with: urls, into: exportDirectory)
    }

    // MARK: - Environment

    /// What names this machine in a merged bundle — the Mac's sharing name
    /// (already what the peer list shows), falling back through less
    /// friendly names rather than a placeholder.
    static var deviceLabel: String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        if let name = Host.current().name, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    /// `macOS 15.2.1`.
    static var platform: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
