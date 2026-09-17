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
        XCTAssertEqual(DiagnosticsCenter.severity(of: "retrying in 2s"), .warning)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "Listening for connections"), .info)
        XCTAssertEqual(DiagnosticsCenter.severity(of: "Viewer admitted 100.64.0.3"), .info)
    }
}
