import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsHost` — bring-up, the on/off switch, and export. One type
/// rather than three app copies because the ordering is easy to get wrong:
/// `recording.stopped` must record before the switch moves, and
/// `recording.exported` must precede the snapshot.
///
/// `DiagnosticsCenter.shared` is process-wide; installed fresh in `setUp`
/// with a per-test `UserDefaults` suite so tests don't leak into each other.
final class DiagnosticsHostTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    private let environment = DiagnosticsEnvironment(
        platform: "test-os",
        appVersion: "0.10.0-rc.3",
        commit: "abc1234",
        configuration: "release",
        architecture: "arm64",
        deviceLabel: "test-device")

    override func setUpWithError() throws {
        suiteName = "DiagnosticsHostTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        DiagnosticsCenter.shared.install(recorder: nil, environment: nil)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @discardableResult
    private func start(_ processEnvironment: [String: String] = [:]) -> DiagnosticsRecorder {
        DiagnosticsHost.start(
            environment: environment,
            defaults: defaults,
            processEnvironment: processEnvironment)
    }

    // MARK: - Bring-up

    /// A candidate records from the first line, carrying the build stamp.
    func testStartOpensTheRecordWithTheBuildStamp() {
        let recorder = start()

        XCTAssertTrue(recorder.isRecording)
        let first = recorder.events().first
        XCTAssertEqual(first?.name, DiagnosticEventName.recordingStarted.rawValue)
        XCTAssertEqual(first?.fields["channel"], .string("releaseCandidate"))
        XCTAssertEqual(first?.fields["app_version"], .string("0.10.0-rc.3"))
        XCTAssertEqual(first?.fields["commit"], .string("abc1234"))
    }

    /// A shipped release doesn't record unless asked, but the recorder is
    /// still installed since the on/off state lives inside it.
    func testStableReleaseInstallsARecorderButDoesNotRecord() {
        let stable = DiagnosticsEnvironment(
            platform: "test-os", appVersion: "0.10.0", commit: "abc1234",
            configuration: "release", architecture: "arm64", deviceLabel: "test-device")
        let recorder = DiagnosticsHost.start(
            environment: stable, defaults: defaults, processEnvironment: [:])

        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.events().isEmpty)
        XCTAssertNotNil(
            DiagnosticsCenter.shared.recorder,
            "the recorder must still be installed — the server and viewer copy this "
                + "reference at construction, and the toggle has to reach them later")
    }

    // MARK: - The switch

    /// The event saying recording stopped must survive, or the bundle reads
    /// like a crash rather than a deliberate stop.
    func testStoppingRecordsItsOwnStopEvent() {
        start()
        DiagnosticsHost.setRecording(false, defaults: defaults)

        let recorder = DiagnosticsCenter.shared.recorder
        XCTAssertEqual(recorder?.isRecording, false)
        XCTAssertEqual(
            recorder?.events().last?.name, DiagnosticEventName.recordingStopped.rawValue)
    }

    /// Stopping keeps what was already recorded — flipped after something
    /// went wrong, so erasing the evidence would be a trap.
    func testStoppingKeepsWhatWasRecorded() {
        let recorder = start()
        recorder.record(.helloSent)
        let before = recorder.events().count

        DiagnosticsHost.setRecording(false, defaults: defaults)
        // +1 for the stop event itself.
        XCTAssertEqual(recorder.events().count, before + 1)
    }

    func testRestartingResumesTheSameRecorder() {
        let recorder = start()
        DiagnosticsHost.setRecording(false, defaults: defaults)
        DiagnosticsHost.setRecording(true, defaults: defaults)

        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(
            recorder.events().last?.name, DiagnosticEventName.recordingStarted.rawValue)
        XCTAssertTrue(
            recorder.events().contains { $0.name == DiagnosticEventName.recordingStopped.rawValue },
            "the earlier stop must still be in the record")
    }

    func testChoicePersistsAcrossRestart() {
        start()
        DiagnosticsHost.setRecording(false, defaults: defaults)

        DiagnosticsCenter.shared.install(recorder: nil, environment: nil)
        let second = start()
        XCTAssertFalse(second.isRecording, "an opt-out must survive into the next launch")
    }

    // MARK: - Export

    func testExportedBundleContainsItsOwnExportEvent() throws {
        let recorder = start()
        recorder.record(.helloSent)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try DiagnosticsHost.export(to: directory)
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: try String(contentsOf: url, encoding: .utf8))

        XCTAssertTrue(
            parsed.events.contains { $0.name == DiagnosticEventName.recordingExported.rawValue })
        XCTAssertEqual(parsed.header.appVersion, "0.10.0-rc.3")
        XCTAssertEqual(parsed.header.platform, "test-os")
        XCTAssertEqual(parsed.header.channel, .releaseCandidate)
    }

    func testExportFilenameNamesTheDevice() throws {
        let recorder = start()
        recorder.record(.helloSent)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try DiagnosticsHost.export(to: directory)
        XCTAssertTrue(url.lastPathComponent.contains("test-device"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".jsonl"))
    }

    /// Exporting with nothing recorded refuses rather than writing an empty
    /// bundle indistinguishable from a session where nothing happened.
    func testExportingNothingRefusesRatherThanWritingAnEmptyBundle() {
        let stable = DiagnosticsEnvironment(
            platform: "test-os", appVersion: "0.10.0", commit: "abc1234",
            configuration: "release", architecture: "arm64", deviceLabel: "test-device")
        DiagnosticsHost.start(
            environment: stable, defaults: defaults, processEnvironment: [:])

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-host-\(UUID().uuidString)")
        XCTAssertThrowsError(try DiagnosticsHost.export(to: directory)) { error in
            XCTAssertEqual(error as? DiagnosticsHostError, .nothingRecorded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The documented workflow (reproduce, stop, export): a stopped
    /// recorder's export must still carry the record of its own export —
    /// an ordinary `record` no-ops when disabled, which would silently
    /// break that guarantee.
    func testExportWhileStoppedStillRecordsItsOwnExport() throws {
        let recorder = start()
        recorder.record(.helloSent)
        DiagnosticsHost.setRecording(false, defaults: defaults)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try DiagnosticsHost.export(to: directory)
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: try String(contentsOf: url, encoding: .utf8))

        XCTAssertTrue(
            parsed.events.contains { $0.name == DiagnosticEventName.recordingExported.rawValue },
            "export while stopped lost its own marker")
        XCTAssertFalse(parsed.header.wasRecording)
        XCTAssertTrue(
            parsed.events.contains { $0.name == DiagnosticEventName.helloSent.rawValue },
            "stopping must keep what was already recorded")
    }

    /// The lifecycle bypass must not become a general back door — it's for
    /// the two events that describe the switch; ordinary recording stays off.
    func testLifecycleBypassDoesNotReopenOrdinaryRecording() {
        let recorder = start()
        DiagnosticsHost.setRecording(false, defaults: defaults)
        let before = recorder.events().count

        recorder.record(.helloSent)
        XCTAssertEqual(recorder.events().count, before, "an ordinary record slipped through")

        recorder.recordLifecycle(.recordingExported)
        XCTAssertEqual(recorder.events().count, before + 1)
    }

    /// `TAILSCREEN_DIAGNOSTICS` pins the live value for the whole run —
    /// applying it only at `start` would let a UI toggle countermand it mid-run.
    func testEnvironmentOverrideSurvivesAUserToggle() throws {
        let forcedOff = ["TAILSCREEN_DIAGNOSTICS": "0"]
        let recorder = DiagnosticsHost.start(
            environment: environment, defaults: defaults, processEnvironment: forcedOff)
        XCTAssertFalse(recorder.isRecording)

        DiagnosticsHost.setRecording(
            true, defaults: defaults, processEnvironment: forcedOff)
        XCTAssertFalse(
            recorder.isRecording,
            "a UI toggle overrode TAILSCREEN_DIAGNOSTICS=0")
        XCTAssertTrue(
            defaults.bool(forKey: DiagnosticsPreference.defaultsKey),
            "the user's choice must still be persisted for the next run")
    }

    /// A macOS PR artifact is stamped `0.0.<PR>` (plist demands numeric),
    /// which classifies as stable — so a host told by CI "this is a
    /// candidate" must be able to say so explicitly.
    func testExplicitChannelOutranksTheVersionString() {
        let prArtifact = DiagnosticsEnvironment(
            platform: "test-os", appVersion: "0.0.311", commit: "abc1234",
            configuration: "release", architecture: "arm64", deviceLabel: "test-device",
            channel: .releaseCandidate)
        XCTAssertEqual(prArtifact.channel, .releaseCandidate)

        let recorder = DiagnosticsHost.start(
            environment: prArtifact, defaults: defaults, processEnvironment: [:])
        XCTAssertTrue(
            recorder.isRecording,
            "a PR artifact must record — it is exactly what testers are handed")
    }

    func testChannelDefaultsToTheVersionDerivedAnswer() {
        let stable = DiagnosticsEnvironment(
            platform: "test-os", appVersion: "0.10.0", commit: "abc1234",
            configuration: "release", architecture: "arm64", deviceLabel: "d")
        XCTAssertEqual(stable.channel, .stable)
    }

    /// The marker and the switch move together — done as two calls, another
    /// thread could append an event before `recording.started` or after
    /// `recording.stopped`.
    func testStartMarkerIsTheFirstEventAndStopMarkerIsTheLast() {
        let recorder = start()
        XCTAssertEqual(
            recorder.events().first?.name, DiagnosticEventName.recordingStarted.rawValue)

        recorder.record(.helloSent)
        DiagnosticsHost.setRecording(false, defaults: defaults)
        XCTAssertEqual(
            recorder.events().last?.name, DiagnosticEventName.recordingStopped.rawValue)

        DiagnosticsHost.setRecording(true, defaults: defaults)
        XCTAssertEqual(
            recorder.events().last?.name, DiagnosticEventName.recordingStarted.rawValue,
            "re-enabling must open the new stretch, not sit behind it")
    }

    /// A failed write must not leave `recording.exported` behind, or the next
    /// successful export claims one that never happened.
    func testFailedWriteDoesNotLeaveAnExportMarkerBehind() {
        let recorder = start()
        recorder.record(.helloSent)
        let before = recorder.events().count

        // A path that can't be created: an existing file used as a directory.
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-not-a-dir-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try DiagnosticsHost.export(to: file.appendingPathComponent("sub")))
        XCTAssertEqual(
            recorder.events().count, before,
            "a failed export left its marker in the recorder")
    }

    /// Two exports inside one second must not overwrite each other — the
    /// filename stamp has one-second resolution.
    func testRepeatedExportsInOneSecondDoNotOverwrite() throws {
        let recorder = start()
        recorder.record(.helloSent)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let at = Date()
        let first = try DiagnosticsHost.export(to: directory, at: at)
        let second = try DiagnosticsHost.export(to: directory, at: at)

        XCTAssertNotEqual(first, second, "the second export replaced the first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testHostErrorsReadAsSentences() {
        for error in [DiagnosticsHostError.notRecording, .nothingRecorded] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("nothingRecorded"), text)
            XCTAssertFalse(text.contains("notRecording"), text)
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    /// `localizedDescription` is the only way to those sentences —
    /// interpolating the error (`"…: \(error)"`) renders the raw enum case
    /// instead.
    func testInterpolatingTheErrorDoesNotProduceTheSentence() {
        for error in [DiagnosticsHostError.notRecording, .nothingRecorded] {
            XCTAssertNotEqual(
                "\(error)", error.localizedDescription,
                "interpolation now matches — re-check the call sites either way")
        }
    }

    // MARK: - The log tee

    /// An existing `LogSink` line lands in the record with no new
    /// instrumentation at the call site.
    func testLogLinesAreCaptured() {
        start()
        DiagnosticsCenter.shared.captureLog(source: "Discovery", message: "found 3 peers")

        let last = DiagnosticsCenter.shared.recorder?.events().last
        XCTAssertEqual(last?.name, DiagnosticEventName.logLine.rawValue)
        XCTAssertEqual(last?.fields["source"], .string("Discovery"))
    }

    func testLogLinesAreNotCapturedWhileStopped() {
        start()
        DiagnosticsHost.setRecording(false, defaults: defaults)
        let before = DiagnosticsCenter.shared.recorder?.events().count ?? 0

        DiagnosticsCenter.shared.captureLog(source: "Discovery", message: "found 3 peers")
        XCTAssertEqual(DiagnosticsCenter.shared.recorder?.events().count, before)
    }

    /// Severity is guessed from the line's own text (`LogSink` has no
    /// levels), biased toward under-classifying.
    func testLogSeverityIsInferredConservatively() {
        XCTAssertEqual(DiagnosticsCenter.severity(of: "node up failed: timeout"), .error)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "acceptLoop fatal: broken pipe"), .error)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "retrying in 2s"), .warning)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "Listening for connections"), .info)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "Viewer admitted 100.64.0.3"), .info)
    }

    /// The author's own `❌`/`⚠` marker outranks a keyword guess.
    func testExplicitMarkersOutrankKeywords() {
        XCTAssertEqual(
            DiagnosticsCenter.severity(of: "⚠ Microphone did not start (busy)"), .warning,
            "an author-marked warning must not be promoted to an error")
        XCTAssertEqual(
            DiagnosticsCenter.severity(
                of: "⚠ Voice uplink unavailable (no device) — continuing without a mic"),
            .warning)
        XCTAssertEqual(
            DiagnosticsCenter.severity(of: "❌ Failed to check auth status: denied"), .error)
    }

    /// A line about surviving errors is a success message, not a failure a
    /// plain keyword scan would flag.
    func testGoodOutcomesAreNotReportedAsFailures() {
        XCTAssertEqual(
            DiagnosticsCenter.severity(
                of: "Server stop: receive loop survived 3 error(s) this session"),
            .info)
        XCTAssertEqual(
            DiagnosticsCenter.severity(of: "recovered 4 packets from parity"), .info)
    }

    // MARK: - Merge

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiagnosticsHostMerge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Writes a bundle out as the app would, so the merge reads real JSONL.
    private func writeBundle(
        role: DiagnosticRole, device: String, events: [DiagnosticEvent], to dir: URL
    ) throws -> URL {
        let bundle = DiagnosticsBundle(
            header: .init(
                role: role, device: device, platform: "test-os",
                appVersion: "0.10.0-rc.14", commit: "abc1234", configuration: "release",
                architecture: "arm64", channel: .releaseCandidate,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                exportedAt: Date(timeIntervalSince1970: 1_800_000_010),
                eventCount: events.count, droppedCount: 0, wasRecording: true),
            events: events)
        let url = dir.appendingPathComponent("\(device).jsonl")
        return try DiagnosticsExport.write(bundle, to: url)
    }

    private func handshakeEvent(
        _ seq: UInt64, _ name: DiagnosticEventName, _ role: DiagnosticRole, at offset: TimeInterval
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            seq: seq, monotonicNs: UInt64(offset * 1_000_000_000),
            wallClock: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            session: 1, role: role, category: .handshake, name: name.rawValue,
            fields: ["ssrc": .int(2)])
    }

    func testMergeCombinesAPickedBundleWithTheLocalRecording() throws {
        let dir = try scratch()
        let recorder = start()
        recorder.record(.helloAckSent, fields: ["ssrc": .int(2)])

        let theirs = try writeBundle(
            role: .viewer, device: "their-pc",
            events: [handshakeEvent(1, .helloAckReceived, .viewer, at: 1.0)], to: dir)

        let written = try DiagnosticsHost.merge(with: [theirs], into: dir)

        let text = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(
            written.lastPathComponent.hasPrefix("tailscreen-merged-"),
            "a merged timeline is named for being merged, not for either side")
        XCTAssertTrue(written.pathExtension == "txt", "it is prose, not a bundle")
        XCTAssertTrue(text.contains("their-pc"), "the picked bundle's device must appear")
        XCTAssertTrue(
            text.contains("test-device"),
            "this device's own recording must be in there — merging it with their file "
                + "is what the caller asked for")
    }

    /// Both files were sent and this Mac was never in the session — merges
    /// what it was given rather than refusing.
    func testMergeWorksWithNoLocalRecording() throws {
        let dir = try scratch()
        let a = try writeBundle(
            role: .sharer, device: "mac-one",
            events: [handshakeEvent(1, .helloAckSent, .sharer, at: 1.0)], to: dir)
        let b = try writeBundle(
            role: .viewer, device: "pc-two",
            events: [handshakeEvent(1, .helloAckReceived, .viewer, at: 1.1)], to: dir)

        let text = try String(
            contentsOf: try DiagnosticsHost.merge(with: [a, b], into: dir), encoding: .utf8)

        XCTAssertTrue(text.contains("mac-one"))
        XCTAssertTrue(text.contains("pc-two"))
    }

    /// Merging is a read — unlike export it must leave no trace in the
    /// recording.
    func testMergeRecordsNothing() throws {
        let dir = try scratch()
        let recorder = start()
        recorder.record(.helloAckSent, fields: ["ssrc": .int(2)])
        let before = recorder.events()

        let theirs = try writeBundle(
            role: .viewer, device: "their-pc",
            events: [handshakeEvent(1, .helloAckReceived, .viewer, at: 1.0)], to: dir)
        _ = try DiagnosticsHost.merge(with: [theirs], into: dir)

        XCTAssertEqual(
            recorder.events(), before,
            "a merge derives a file from bundles it does not change; an export is the "
                + "operation that writes its own marker")
    }

    /// Same one-second-resolution trap as the bundle filename.
    func testTwoMergesInOneSecondBothSurvive() throws {
        let dir = try scratch()
        let at = Date(timeIntervalSince1970: 1_800_000_500)
        let theirs = try writeBundle(
            role: .viewer, device: "their-pc",
            events: [handshakeEvent(1, .helloAckReceived, .viewer, at: 1.0)], to: dir)

        let first = try DiagnosticsHost.merge(with: [theirs], into: dir, at: at)
        let second = try DiagnosticsHost.merge(with: [theirs], into: dir, at: at)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// An unreadable or wrong file names itself — a merge takes several
    /// paths, so "it could not be read" alone wouldn't say which.
    func testMergeFailuresNameTheOffendingFile() throws {
        let dir = try scratch()

        let missing = dir.appendingPathComponent("not-here.jsonl")
        XCTAssertThrowsError(try DiagnosticsHost.merge(with: [missing], into: dir)) { error in
            guard case DiagnosticsHostError.bundleUnreadable(let name, _) = error else {
                return XCTFail("expected bundleUnreadable, got \(error)")
            }
            XCTAssertEqual(name, "not-here.jsonl")
        }

        let junk = dir.appendingPathComponent("notes.jsonl")
        try "this is not a bundle".write(to: junk, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DiagnosticsHost.merge(with: [junk], into: dir)) { error in
            XCTAssertEqual(error as? DiagnosticsHostError, .notABundle(name: "notes.jsonl"))
            XCTAssertTrue(
                (error as? DiagnosticsHostError)?.errorDescription?.contains("notes.jsonl") == true,
                "the sentence a user reads has to name the file too, not just the case")
        }
    }

    func testMergeWithNothingAtAllRefuses() throws {
        let dir = try scratch()
        XCTAssertThrowsError(try DiagnosticsHost.merge(with: [], into: dir)) { error in
            XCTAssertEqual(error as? DiagnosticsHostError, .nothingToMerge)
        }
    }
}
