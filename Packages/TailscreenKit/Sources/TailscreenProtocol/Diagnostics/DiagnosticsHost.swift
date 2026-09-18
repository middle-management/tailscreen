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

    /// The channel this build is on.
    ///
    /// **Stored, not re-derived**, because a host can know something the
    /// version string cannot say. A macOS PR artifact is stamped `0.0.<PR>` —
    /// `CFBundleShortVersionString` has to be numeric — which classifies as an
    /// ordinary stable release, so a host told by CI "this is a candidate"
    /// needs somewhere to put that. Recomputing from `appVersion` here silently
    /// discarded it: the recorder started off while the Settings toggle, which
    /// read the host's own answer, said on. The two disagreed about whether the
    /// machine was recording, which is the worst thing a privacy-facing switch
    /// can do.
    ///
    /// The initialiser defaults it to the version-derived answer, so a host
    /// with nothing extra to say passes nothing.
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
        if enabled {
            recorder.recordLifecycle(.recordingStarted, fields: startFields(environment))
        }
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
        // The marker and the switch move under ONE lock acquisition. Doing them
        // separately let a transport or logging thread append in between, so an
        // event could land before the `recording.started` that claims to open
        // the session, or after the `recording.stopped` that claims to close
        // it. Either reads as the recorder lying about its own lifetime.
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
        // The marker goes into the OUTGOING snapshot first and is committed to
        // the live recorder only after the write succeeds. Recording it up
        // front meant a failed write — a full disk, a directory that could not
        // be created — still left `recording.exported` behind, so the next
        // bundle that DID succeed claimed an export that never happened.
        //
        // Staged by the RECORDER, so it carries the current monotonic elapsed:
        // the merge reconstructs time as anchor + elapsed, and a marker
        // borrowing the previous event's elapsed would render at that event's
        // moment rather than now.
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
        // Committed only now, so the recorder's own history matches what
        // actually reached the disk. `recordLifecycle`, because exporting while
        // STOPPED is the documented workflow and an ordinary `record` no-ops.
        recorder.recordLifecycle(.recordingExported)
        return written
    }

    // MARK: - Merge

    /// Merge this process's current recording with bundles exported elsewhere,
    /// and write the result as a readable timeline.
    ///
    /// This is the half of the feature that makes recording two sides worth
    /// doing. One side's bundle says what this machine did; the pair says what
    /// *happened*, and the difference is the whole point — a viewer that gave
    /// up after thirty seconds looks identical whether the sharer never saw it
    /// or saw it and parked it on an approval prompt.
    ///
    /// Unlike ``export(to:at:)`` this records **nothing**. A merge is a read:
    /// it derives a `.txt` from bundles that are themselves unchanged, so
    /// there is no marker a later reader would need, and no new registry name
    /// to keep forever. Exporting is the thing that alters a bundle's history;
    /// reading one is not.
    ///
    /// The local recording is included **when there is one with events in it**,
    /// and simply left out otherwise. That case is real rather than defensive —
    /// somebody sent both files and this Mac was never in the session — and
    /// erroring there would refuse to do the obvious thing with the arguments
    /// given. Merging a single bundle is likewise allowed: it renders that
    /// bundle's own timeline, which is the honest answer to being handed one
    /// file.
    ///
    /// Bundles that share no handshake still merge; the timeline says so under
    /// its clock-alignment notes rather than interleaving two unrelated
    /// stories as though they were one.
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
                // Name the file. A merge is given several and a bare failure
                // leaves the person guessing which one to look at.
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
        // Atomic, for the reason `write(_:to:)` is: a half-written timeline
        // that reads as a short session is worse than none, because nothing
        // about it looks wrong.
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

    /// Plain sentences, because these reach a user.
    ///
    /// The default rendering put the enum case itself in front of somebody —
    /// "could not be written: nothingRecorded" — which is both meaningless and
    /// wrong: no write was attempted. Each case says what actually happened and
    /// what to do about it.
    public var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Diagnostics are not running, so there is nothing to export."
        case .nothingRecorded:
            return
                "Nothing has been recorded yet. Turn recording on, reproduce the "
                + "problem, then export."
        case .bundleUnreadable(let name, let reason):
            // The name, because a merge is given several files and "it could
            // not be read" does not say which to go and look at.
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
