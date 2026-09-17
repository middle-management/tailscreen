import Foundation

/// The mac app's half of diagnostics: the facts only this platform knows, and
/// the places only this app records from.
///
/// Everything portable — creating the recorder, the on/off switch and its
/// ordering, the export — lives in `DiagnosticsHost` (TailscreenProtocol) and
/// is shared with the GTK and WinUI apps. What is left here is genuinely
/// mac-specific: the OS version string, the Mac's sharing name, and
/// `~/Library/Logs` as the place a person expects to find a file they are
/// about to send someone.
///
/// **Not `@MainActor`**, deliberately. The recorder is written to from the
/// capture callbacks, the UDP receive loops and the sharer's sweep timers as
/// well as from the UI, and it is thread-safe by construction — that is what
/// its internal lock is for. Isolating this facade to the main actor would
/// force every one of those call sites into a hop, which on the receive path
/// means recording changes the timing of the thing it is recording.
enum AppDiagnostics {

    /// The build and machine facts that go in a bundle's header.
    static var environment: DiagnosticsEnvironment {
        DiagnosticsEnvironment(
            platform: platform,
            appVersion: BuildInfo.marketingVersion,
            commit: BuildInfo.commit,
            configuration: BuildInfo.configuration,
            architecture: BuildInfo.architecture,
            deviceLabel: deviceLabel)
    }

    /// The process recorder, once `start()` has run.
    ///
    /// Optional because it is: before start-up there is none, and code that
    /// records is written to tolerate that rather than to assume an order.
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

    /// Record which surface the user is looking at.
    ///
    /// The macOS app has no stored "current view" — `MainWindowView` derives
    /// its pane per render from `sharingState` and `connectionState`, and
    /// `.claude/rules/macos-app.md` is explicit that even `NodeBringUpPhase` is
    /// a projection rather than a source of truth. So surfaces report
    /// themselves, through `View.recordsDiagnosticSurface(_:)`. Deriving it
    /// centrally instead would mean re-implementing the pane logic in a second
    /// place, where it would silently fall out of step with the first.
    /// Record a surface directly, for the ones SwiftUI's modifier cannot
    /// reach — today the viewer's own `NSWindow`.
    ///
    /// `@MainActor` and routed through `DiagnosticSurfaceTracker` so these
    /// share the SwiftUI surfaces' bookkeeping: without it a `view.hidden`
    /// could be recorded for a window that was never opened, and a reader
    /// counting shows against hides would find them unbalanced.
    @MainActor
    static func viewShown(_ surface: String) {
        DiagnosticSurfaceTracker.shared.shown(surface)
    }

    @MainActor
    static func viewHidden(_ surface: String) {
        DiagnosticSurfaceTracker.shared.hidden(surface)
    }

    /// The raw emit the tracker calls once it has decided the transition is
    /// real. Not for direct use — go through `viewShown` / `viewHidden`.
    static func emitViewShown(_ surface: String) {
        recorder?.record(.viewShown, fields: ["surface": .string(surface)])
    }

    static func emitViewHidden(_ surface: String) {
        recorder?.record(.viewHidden, fields: ["surface": .string(surface)])
    }

    /// Record a failure that was surfaced to the user.
    ///
    /// Hung off `AppState.presentError`, which every alert-shaped error in the
    /// app already funnels through — so this needs one call site rather than
    /// one per failure, and a failure added later is recorded without anyone
    /// remembering to. The stable `TS-…` code is what joins a bundle onto the
    /// error registry; the message is not recorded, because it is prose that
    /// varies with interpolated detail while the code does not.
    static func fault(code: String, title: String) {
        recorder?.record(
            .faultSurfaced,
            fields: ["code": .string(code), "title": .string(title)])
    }

    // MARK: - Export

    /// Where bundles are written: `~/Library/Logs/Tailscreen/`.
    ///
    /// `Library/Logs` rather than Application Support because that is where a
    /// Mac user is used to finding files they are about to send someone, it is
    /// where Console.app looks, and because these are disposable — which
    /// Application Support's contents are not.
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

    // MARK: - Environment

    /// What names this machine in a merged bundle.
    ///
    /// The Mac's sharing name ("Robert's MacBook Pro") rather than the DNS
    /// host name: it is what the person reading the bundle calls the machine,
    /// and it is already what the peer list shows them. Falls back through the
    /// less friendly names rather than to a placeholder, because an
    /// unidentifiable column is the one thing a merged timeline cannot afford.
    static var deviceLabel: String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        if let name = Host.current().name, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    /// `macOS 15.2.1` — the OS version, which is the first thing anybody asks
    /// about a capture or permissions problem on this platform.
    static var platform: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
