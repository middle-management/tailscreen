import Foundation

/// The build and machine facts that go in a bundle's header. Passed in, not
/// read here, since each platform stamps its own (`BuildInfo` is per-app,
/// device label comes from three different APIs, "platform" means something
/// different per OS).
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

    /// The channel this build is on. Stored, not re-derived — a macOS PR
    /// artifact's numeric-only version classifies as stable by re-derivation
    /// alone, which made the recorder and the Settings toggle disagree about
    /// whether the machine was recording. Defaults to the version-derived
    /// answer when a host has nothing extra to say.
    public var channel: ReleaseChannel

    public init(
        platform: String,
        appVersion: String,
        commit: String,
        configuration: String,
        architecture: String,
        deviceLabel: String,
        channel: ReleaseChannel? = nil
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.commit = commit
        self.configuration = configuration
        self.architecture = architecture
        self.deviceLabel = deviceLabel
        self.channel = channel ?? ReleaseChannel.classify(version: appVersion)
    }
}

/// Bring-up, the on/off switch, and export — the three things every host
/// needs and none of them platform-specific. Written once here, not three
/// times in the apps, since the ordering is easy to get subtly wrong (see
/// `.claude/rules/diagnostics.md`'s "Switch semantics").
public enum DiagnosticsHost {

    /// Create the process recorder, install it, and open the session record.
    /// Recording starts on or off per ``DiagnosticsPreference`` — on in a
    /// release candidate, off in a shipped release unless asked, on locally.
    /// The recorder installs either way; see ``DiagnosticsCenter/recorder``.
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
            // `.app`, not a fixed side: a process can share and view at once,
            // so role belongs to each event, not the recorder.
            defaultRole: .app,
            deviceLabel: environment.deviceLabel,
            enabled: enabled)
        DiagnosticsCenter.shared.install(recorder: recorder, environment: environment)
        if enabled {
            recorder.recordLifecycle(.recordingStarted, fields: startFields(environment))
        }
        return recorder
    }

    /// Turn recording on or off and persist the choice, so it outranks the
    /// channel default on the next launch either way. Turning it off keeps
    /// what was already recorded — a switch that erased it would be a trap
    /// for the person who just hit a problem.
    public static func setRecording(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // Always persisted — the user's preference must survive the next launch.
        DiagnosticsPreference.save(enabled, defaults: defaults)
        guard let recorder = DiagnosticsCenter.shared.recorder else { return }

        // `TAILSCREEN_DIAGNOSTICS` pins the live value for the whole run, so a
        // harness stays reproducible regardless of a mid-run UI toggle.
        let effective: Bool
        if case .forced(let forced) = DiagnosticsPreference.forcedBy(processEnvironment) {
            effective = forced
        } else {
            effective = enabled
        }
        // Marker and switch move under one lock acquisition, or a concurrent
        // append could land outside the session it claims to be in.
        if effective {
            recorder.setRecording(
                true,
                markerName: .recordingStarted,
                markerFields: DiagnosticsCenter.shared.environment.map(startFields) ?? [:])
        } else {
            recorder.setRecording(false, markerName: .recordingStopped)
        }
    }

    /// The build stamp that opens a session record.
    static func startFields(_ environment: DiagnosticsEnvironment) -> [String: DiagnosticValue] {
        [
            "app_version": .string(environment.appVersion),
            "commit": .string(environment.commit),
            "channel": .string(environment.channel.rawValue),
            "configuration": .string(environment.configuration),
            "architecture": .string(environment.architecture),
            "platform": .string(environment.platform)
        ]
    }

    /// Write the current recording into `directory` and return the file.
    /// Refuses to write an empty bundle when nothing was recorded, rather
    /// than wasting the round trip this feature exists to save.
    @discardableResult
    public static func export(to directory: URL, at date: Date = Date()) throws -> URL {
        guard let recorder = DiagnosticsCenter.shared.recorder else {
            throw DiagnosticsHostError.notRecording
        }
        // Emptiness tested before the marker is written, or the marker itself
        // makes it non-empty and the guard can never fire again.
        guard !recorder.snapshot().events.isEmpty else {
            throw DiagnosticsHostError.nothingRecorded
        }
        // The marker goes into the outgoing snapshot first, committed to the
        // live recorder only after the write succeeds — a failed write must
        // not leave `recording.exported` behind for a later export to inherit.
        let snapshot = recorder.snapshotStaging(.recordingExported)

        let environment =
            DiagnosticsCenter.shared.environment
            ?? DiagnosticsEnvironment(
                platform: "unknown", appVersion: "dev", commit: "unknown",
                configuration: "unknown", architecture: "unknown",
                deviceLabel: snapshot.deviceLabel)
        let bundle = DiagnosticsBundle.make(
            from: snapshot, environment: environment, exportedAt: date)
        let url = directory.appendingPathComponent(
            DiagnosticsExport.uniqueFilename(
                role: snapshot.role, device: snapshot.deviceLabel, at: date,
                existsAtPath: { name in
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(name).path)
                }))
        let written = try DiagnosticsExport.write(bundle, to: url)
        // Committed only now, so history matches what reached disk.
        // `recordLifecycle`, since exporting while stopped is a documented workflow.
        recorder.recordLifecycle(.recordingExported)
        return written
    }

    // MARK: - Merge

    /// Merge this process's current recording with bundles exported
    /// elsewhere, and write the result as a readable timeline — the half of
    /// the feature that makes recording two sides worth doing.
    ///
    /// Unlike ``export(to:at:)`` this records nothing: it derives a `.txt`
    /// from unchanged bundles, so there's no marker or registry name to keep.
    ///
    /// The local recording is included only if it has events, and merging a
    /// single bundle is allowed (renders that bundle's own timeline).
    /// Bundles sharing no handshake still merge, noted under clock-alignment
    /// rather than interleaved as one story.
    ///
    /// - Parameters:
    ///   - urls: exported bundles to merge in, in any order.
    ///   - directory: where the rendered timeline is written.
    /// - Returns: the file written.
    @discardableResult
    public static func merge(
        with urls: [URL],
        into directory: URL,
        at date: Date = Date()
    ) throws -> URL {
        var bundles: [DiagnosticsBundle] = []
        for url in urls {
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                // Name the file — a merge is given several, and a bare failure leaves a guess.
                throw DiagnosticsHostError.bundleUnreadable(
                    name: url.lastPathComponent, reason: error.localizedDescription)
            }
            do {
                bundles.append(try DiagnosticsBundle.parse(jsonLines: text))
            } catch {
                throw DiagnosticsHostError.notABundle(name: url.lastPathComponent)
            }
        }

        // The local side, if this process has one worth adding.
        if let recorder = DiagnosticsCenter.shared.recorder {
            let snapshot = recorder.snapshot()
            if !snapshot.events.isEmpty {
                let environment =
                    DiagnosticsCenter.shared.environment
                    ?? DiagnosticsEnvironment(
                        platform: "unknown", appVersion: "dev", commit: "unknown",
                        configuration: "unknown", architecture: "unknown",
                        deviceLabel: snapshot.deviceLabel)
                bundles.append(
                    DiagnosticsBundle.make(
                        from: snapshot, environment: environment, exportedAt: date))
            }
        }

        guard !bundles.isEmpty else { throw DiagnosticsHostError.nothingToMerge }

        let url = directory.appendingPathComponent(
            DiagnosticsExport.uniqueMergedFilename(
                at: date,
                existsAtPath: { name in
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(name).path)
                }))
        let text = DiagnosticsExport.renderTimeline(DiagnosticsMerge.merge(bundles))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        // Atomic, like `write(_:to:)` — a half-written timeline looks like a short session, not a bug.
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}

public enum DiagnosticsHostError: Error, LocalizedError, Equatable {
    /// No recorder has ever been created in this process.
    case notRecording
    /// Recording is on but nothing has happened yet.
    case nothingRecorded
    /// A file picked for a merge could not be read at all.
    case bundleUnreadable(name: String, reason: String)
    /// A file picked for a merge was read but is not a diagnostics bundle.
    case notABundle(name: String)
    /// A merge was asked for with no files and no local recording.
    case nothingToMerge

    /// Plain sentences, since these reach a user — the default rendering
    /// puts the raw enum case in front of them, which is meaningless.
    public var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Diagnostics are not running, so there is nothing to export."
        case .nothingRecorded:
            return
                "Nothing has been recorded yet. Turn recording on, reproduce the "
                + "problem, then export."
        case .bundleUnreadable(let name, let reason):
            return "\(name) could not be read: \(reason)"
        case .notABundle(let name):
            return
                "\(name) is not a Tailscreen diagnostics file. Pick a .jsonl "
                + "file exported from Tailscreen."
        case .nothingToMerge:
            return
                "There is nothing to merge: no files were picked and this "
                + "device has recorded nothing yet."
        }
    }
}
