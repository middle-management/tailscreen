import Foundation

/// The build and machine facts that go in a bundle's header.
///
/// Passed in rather than read here because each platform stamps its own:
/// `BuildInfo` is deliberately a per-app file (its commit SHA is rewritten by
/// that platform's workflow), the device label comes from three different
/// APIs, and "platform" means a macOS version, a distro or a Windows build
/// depending on who is asking.
public struct DiagnosticsEnvironment: Sendable, Equatable {
    /// `macOS 15.2`, `Ubuntu 24.04`, `Windows 11 26100` — whatever that
    /// platform's first troubleshooting question is about.
    public var platform: String
    /// Marketing version, e.g. `0.10.0-rc.2`, or `dev` for an unstamped build.
    public var appVersion: String
    /// Short commit SHA, as `BuildInfo.commit` stamps it.
    public var commit: String
    /// `debug` or `release`.
    public var configuration: String
    public var architecture: String
    /// What names this machine in a merged bundle — the name the person
    /// reading it calls the machine.
    public var deviceLabel: String

    public init(
        platform: String,
        appVersion: String,
        commit: String,
        configuration: String,
        architecture: String,
        deviceLabel: String
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.commit = commit
        self.configuration = configuration
        self.architecture = architecture
        self.deviceLabel = deviceLabel
    }

    /// The channel this build is on, derived from ``appVersion`` by the same
    /// rule `scripts/release-version.sh` applies to the tag.
    public var channel: ReleaseChannel { ReleaseChannel.classify(version: appVersion) }
}

/// Bring-up, the on/off switch, and export — the three things every host needs
/// and none of them platform-specific.
///
/// Written once here rather than three times in the apps because the sequence
/// has ordering in it that is easy to get subtly wrong and impossible to
/// notice: the `recording.stopped` event has to be recorded *before* the
/// switch moves or it is itself dropped, the log tee has to be attached and
/// detached in step with the recorder or a disabled build keeps capturing log
/// lines, and the `recording.exported` event has to precede the snapshot or a
/// bundle never contains the record of its own export. Three hosts getting
/// that right independently is three chances to get it wrong.
public enum DiagnosticsHost {

    /// Create the process recorder, install it, and open the session record.
    ///
    /// Recording starts on or off per ``DiagnosticsPreference`` — **on in a
    /// release candidate**, off in a shipped release unless the user asked,
    /// on in a local build. The recorder is installed either way, because the
    /// on/off state lives inside it; see ``DiagnosticsCenter/recorder``.
    @discardableResult
    public static func start(
        environment: DiagnosticsEnvironment,
        defaults: UserDefaults = .standard,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiagnosticsRecorder {
        let enabled = DiagnosticsPreference.load(
            defaults: defaults,
            channel: environment.channel,
            environment: processEnvironment)
        let recorder = DiagnosticsRecorder(
            // `.app` rather than a fixed side: a process can be sharing to one
            // person and watching another at the same time, so the role
            // belongs to each event. `DiagnosticsMerge` pairs on the events.
            defaultRole: .app,
            deviceLabel: environment.deviceLabel,
            enabled: enabled)
        DiagnosticsCenter.shared.install(recorder: recorder, environment: environment)
        if enabled { recordStart(recorder, environment) }
        return recorder
    }

    /// Turn recording on or off and persist the choice.
    ///
    /// Persisting is what makes the choice outrank the channel default in both
    /// directions: a tester who turns it off stays off when the next candidate
    /// is installed, and a release user who turns it on stays on.
    ///
    /// Turning it **off keeps what was already recorded** — the user who flips
    /// the switch after something went wrong wants to hand over what just
    /// happened, and a switch that also erased it would be a trap.
    public static func setRecording(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // The choice is always persisted — that is the user's preference and it
        // must survive into the next launch.
        DiagnosticsPreference.save(enabled, defaults: defaults)
        guard let recorder = DiagnosticsCenter.shared.recorder else { return }

        // But `TAILSCREEN_DIAGNOSTICS` pins the LIVE value for the whole run,
        // and that is the entire point of it: a harness sets it so the run is
        // reproducible regardless of what is stored on the machine — or of what
        // somebody clicks while it is going. Applying the override only at
        // `start` left a macOS toggle able to countermand it mid-run, which
        // made scripted runs depend on nobody touching the UI.
        let effective: Bool
        if case .forced(let forced) = DiagnosticsPreference.forcedBy(processEnvironment) {
            effective = forced
        } else {
            effective = enabled
        }
        if effective {
            recorder.setRecording(true)
            if let environment = DiagnosticsCenter.shared.environment {
                recordStart(recorder, environment)
            }
        } else {
            // `recordLifecycle`, so this survives regardless of ordering: an
            // ordinary `record` would be dropped the instant the switch moved,
            // and the bundle would simply end — reading as a crash rather than
            // as a deliberate stop.
            recorder.recordLifecycle(.recordingStopped)
            recorder.setRecording(false)
        }
    }

    private static func recordStart(
        _ recorder: DiagnosticsRecorder, _ environment: DiagnosticsEnvironment
    ) {
        recorder.record(
            .recordingStarted,
            fields: [
                "app_version": .string(environment.appVersion),
                "commit": .string(environment.commit),
                "channel": .string(environment.channel.rawValue),
                "configuration": .string(environment.configuration),
                "architecture": .string(environment.architecture),
                "platform": .string(environment.platform)
            ])
    }

    /// Write the current recording into `directory` and return the file.
    ///
    /// Refuses rather than writing an empty bundle when nothing was recorded:
    /// a file full of nothing is indistinguishable from a session where
    /// nothing happened, and handing one over wastes the round trip this
    /// feature exists to save.
    @discardableResult
    public static func export(to directory: URL, at date: Date = Date()) throws -> URL {
        guard let recorder = DiagnosticsCenter.shared.recorder else {
            throw DiagnosticsHostError.notRecording
        }
        // Before the snapshot, so a bundle always contains the record of its
        // own export — which is how you tell a bundle somebody sent you from
        // one they exported, looked at, and exported again after actually
        // reproducing the problem.
        // Emptiness is tested BEFORE the marker is written, or the marker is
        // the thing that makes it non-empty and the guard can never fire again.
        guard !recorder.snapshot().events.isEmpty else {
            throw DiagnosticsHostError.nothingRecorded
        }
        // `recordLifecycle`, not `record`: exporting while STOPPED is the
        // documented workflow — reproduce, stop, hand the file over — and an
        // ordinary `record` no-ops when disabled, so that path produced a
        // bundle carrying no record of its own export.
        recorder.recordLifecycle(.recordingExported)
        let snapshot = recorder.snapshot()

        // `start` installs the environment alongside the recorder, so a
        // recorder without one cannot normally exist. The fallback names the
        // unknowns rather than inventing plausible values — a header claiming
        // a version it never knew is worse than one that says it does not know.
        let environment =
            DiagnosticsCenter.shared.environment
            ?? DiagnosticsEnvironment(
                platform: "unknown", appVersion: "dev", commit: "unknown",
                configuration: "unknown", architecture: "unknown",
                deviceLabel: snapshot.deviceLabel)
        let bundle = DiagnosticsBundle.make(
            from: snapshot, environment: environment, exportedAt: date)
        let url = directory.appendingPathComponent(
            DiagnosticsExport.filename(
                role: snapshot.role, device: snapshot.deviceLabel, at: date))
        return try DiagnosticsExport.write(bundle, to: url)
    }
}

public enum DiagnosticsHostError: Error, Equatable {
    /// No recorder has ever been created in this process.
    case notRecording
    /// Recording is on but nothing has happened yet.
    case nothingRecorded
}
