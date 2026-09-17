import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsHost` — bring-up, the on/off switch, and export.
///
/// This exists as one type rather than three copies in three apps because the
/// sequence has ordering in it that is easy to get wrong and impossible to
/// notice at a glance: `recording.stopped` has to be recorded before the
/// switch moves or the event is itself dropped, and `recording.exported` has
/// to precede the snapshot or a bundle never contains the record of its own
/// export. Those orderings are what this suite pins.
///
/// `DiagnosticsCenter.shared` is process-wide, so these tests write to it. It
/// is installed fresh in `setUp` and the `UserDefaults` suite is per-test, so
/// they neither leak into each other nor touch a developer's real settings.
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

    /// A candidate records from the first line, and that line carries the
    /// build stamp — which is the first thing anybody reading a bundle needs.
    func testStartOpensTheRecordWithTheBuildStamp() {
        let recorder = start()

        XCTAssertTrue(recorder.isRecording)
        let first = recorder.events().first
        XCTAssertEqual(first?.name, DiagnosticEventName.recordingStarted.rawValue)
        XCTAssertEqual(first?.fields["channel"], .string("releaseCandidate"))
        XCTAssertEqual(first?.fields["app_version"], .string("0.10.0-rc.3"))
        XCTAssertEqual(first?.fields["commit"], .string("abc1234"))
    }

    /// A shipped release does not record unless asked — and the recorder is
    /// still installed, because the on/off state lives inside it.
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

    /// The ordering that motivates this type existing: the event saying
    /// recording stopped must survive, or the bundle just ends and reads like
    /// a crash rather than a deliberate stop.
    func testStoppingRecordsItsOwnStopEvent() {
        start()
        DiagnosticsHost.setRecording(false, defaults: defaults)

        let recorder = DiagnosticsCenter.shared.recorder
        XCTAssertEqual(recorder?.isRecording, false)
        XCTAssertEqual(
            recorder?.events().last?.name, DiagnosticEventName.recordingStopped.rawValue)
    }

    /// Stopping keeps what was already recorded: the user flips the switch
    /// *after* something went wrong, and a switch that erased the evidence
    /// would be a trap.
    func testStoppingKeepsWhatWasRecorded() {
        let recorder = start()
        recorder.record(.helloSent)
        let before = recorder.events().count

        DiagnosticsHost.setRecording(false, defaults: defaults)
        // +1 for the stop event itself.
        XCTAssertEqual(recorder.events().count, before + 1)
    }

    /// Turning it back on resumes into the same recorder, so the session
    /// record is continuous rather than starting over.
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

    /// The choice persists, so a tester who opts out stays opted out when the
    /// next candidate is installed.
    func testChoicePersistsAcrossRestart() {
        start()
        DiagnosticsHost.setRecording(false, defaults: defaults)

        DiagnosticsCenter.shared.install(recorder: nil, environment: nil)
        let second = start()
        XCTAssertFalse(second.isRecording, "an opt-out must survive into the next launch")
    }

    // MARK: - Export

    /// A bundle always contains the record of its own export — which is how
    /// you tell one somebody sent you from one they exported, looked at, and
    /// exported again after actually reproducing the problem.
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

    /// The filename names the device, so two bundles in a chat thread stay
    /// distinguishable.
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
    /// file: a bundle full of nothing is indistinguishable from a session
    /// where nothing happened, and handing one over wastes the round trip this
    /// whole feature exists to save.
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

    /// **The documented workflow: reproduce, stop, export.** A stopped
    /// recorder keeps what it has and export is deliberately still allowed —
    /// so the bundle must still carry the record of its own export. An
    /// ordinary `record` no-ops when disabled, which silently broke the one
    /// guarantee `DiagnosticsBundle` makes about every bundle.
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

    /// The lifecycle bypass must not become a general back door: it is for the
    /// two events that describe the switch, and ordinary recording stays off.
    func testLifecycleBypassDoesNotReopenOrdinaryRecording() {
        let recorder = start()
        DiagnosticsHost.setRecording(false, defaults: defaults)
        let before = recorder.events().count

        recorder.record(.helloSent)
        XCTAssertEqual(recorder.events().count, before, "an ordinary record slipped through")

        recorder.recordLifecycle(.recordingExported)
        XCTAssertEqual(recorder.events().count, before + 1)
    }

    /// `TAILSCREEN_DIAGNOSTICS` pins the LIVE value for the whole run — that is
    /// the entire point of it. Applying it only at `start` left a UI toggle
    /// able to countermand it mid-run, which made a scripted run depend on
    /// nobody clicking anything.
    func testEnvironmentOverrideSurvivesAUserToggle() throws {
        let forcedOff = ["TAILSCREEN_DIAGNOSTICS": "0"]
        let recorder = DiagnosticsHost.start(
            environment: environment, defaults: defaults, processEnvironment: forcedOff)
        XCTAssertFalse(recorder.isRecording)

        // The user flips the switch on. The choice is stored, but the run
        // stays as the harness pinned it.
        DiagnosticsHost.setRecording(
            true, defaults: defaults, processEnvironment: forcedOff)
        XCTAssertFalse(
            recorder.isRecording,
            "a UI toggle overrode TAILSCREEN_DIAGNOSTICS=0")
        XCTAssertTrue(
            defaults.bool(forKey: DiagnosticsPreference.defaultsKey),
            "the user's choice must still be persisted for the next run")
    }

    /// The host's own channel must reach the policy. A macOS PR artifact is
    /// stamped `0.0.<PR>` (the plist demands numeric), which classifies as a
    /// stable release — so a host told by CI "this is a candidate" has to be
    /// able to say so. Re-deriving from `appVersion` silently discarded it and
    /// left the recorder off while the Settings toggle said on.
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

    /// Omitting it still derives from the version, so a host with nothing extra
    /// to say passes nothing.
    func testChannelDefaultsToTheVersionDerivedAnswer() {
        let stable = DiagnosticsEnvironment(
            platform: "test-os", appVersion: "0.10.0", commit: "abc1234",
            configuration: "release", architecture: "arm64", deviceLabel: "d")
        XCTAssertEqual(stable.channel, .stable)
    }

    /// The marker and the switch move together. Done as two calls, a transport
    /// or logging thread can append in between — landing an event before the
    /// `recording.started` that claims to open the session, or after the
    /// `recording.stopped` that claims to close it.
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
    /// bundle that DOES succeed claims an export that never happened.
    func testFailedWriteDoesNotLeaveAnExportMarkerBehind() {
        let recorder = start()
        recorder.record(.helloSent)
        let before = recorder.events().count

        // A path that cannot be created: an existing FILE used as a directory.
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
    /// filename stamp has one-second resolution and a double-click is enough.
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

    /// The errors reach a person, so they are sentences rather than enum cases.
    func testHostErrorsReadAsSentences() {
        for error in [DiagnosticsHostError.notRecording, .nothingRecorded] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("nothingRecorded"), text)
            XCTAssertFalse(text.contains("notRecording"), text)
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    // MARK: - The log tee

    /// The free coverage: an existing `LogSink` line lands in the record with
    /// no new instrumentation at the call site.
    func testLogLinesAreCaptured() {
        start()
        DiagnosticsCenter.shared.captureLog(source: "Discovery", message: "found 3 peers")

        let last = DiagnosticsCenter.shared.recorder?.events().last
        XCTAssertEqual(last?.name, DiagnosticEventName.logLine.rawValue)
        XCTAssertEqual(last?.fields["source"], .string("Discovery"))
    }

    /// A disabled recorder captures nothing, so a stable release pays a
    /// Boolean load per log line and nothing else.
    func testLogLinesAreNotCapturedWhileStopped() {
        start()
        DiagnosticsHost.setRecording(false, defaults: defaults)
        let before = DiagnosticsCenter.shared.recorder?.events().count ?? 0

        DiagnosticsCenter.shared.captureLog(source: "Discovery", message: "found 3 peers")
        XCTAssertEqual(DiagnosticsCenter.shared.recorder?.events().count, before)
    }

    /// Severity is guessed from the line's own text, because `LogSink` has no
    /// levels. Biased toward under-classifying: a false `error` sends a reader
    /// chasing a non-problem.
    func testLogSeverityIsInferredConservatively() {
        XCTAssertEqual(DiagnosticsCenter.severity(of: "node up failed: timeout"), .error)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "acceptLoop fatal: broken pipe"), .error)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "retrying in 2s"), .warning)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "Listening for connections"), .info)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "Viewer admitted 100.64.0.3"), .info)
    }

    /// The author's own marker outranks the prose. This codebase prefixes log
    /// lines with `❌` and `⚠` where it means them, and that is real severity
    /// information written by someone who knew what the line meant — guessing
    /// from keywords while ignoring it would be strictly worse.
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

    /// A line about *surviving* errors is a success message. This is the one
    /// false positive a plain keyword scan produces against the real call
    /// sites, and it is the shape that would send a reader chasing a
    /// non-problem in every clean session's bundle.
    func testGoodOutcomesAreNotReportedAsFailures() {
        XCTAssertEqual(
            DiagnosticsCenter.severity(
                of: "Server stop: receive loop survived 3 error(s) this session"),
            .info)
        XCTAssertEqual(
            DiagnosticsCenter.severity(of: "recovered 4 packets from parity"), .info)
    }
}
