import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenTransport

/// `PrintLogSink`'s tee into the diagnostics recorder, and the one call site
/// that opts out of it.
///
/// Here rather than in `TailscreenProtocolTests` because the sink lives in
/// TailscreenTransport, and this is the test target that already depends on
/// it. The sink is `package`-visible, which reaches a test target of the same
/// package.
///
/// The opt-out is worth pinning because its failure is silent and it is a
/// disclosure promise, not a behaviour: the bundle header tells the person
/// sending the file that it carries no sign-in details, and `TailscaleAuth`
/// logs the signed-in account's display name in plain prose. Redaction cannot
/// help — it deliberately keeps names, and nothing in free text distinguishes
/// an account name from a device name — so the only thing standing between
/// that line and the bundle is this flag.
final class LogSinkDiagnosticsTeeTests: XCTestCase {

    private var recorder = DiagnosticsRecorder(
        defaultRole: .sharer, deviceLabel: "test-device", enabled: true)

    override func setUp() {
        super.setUp()
        recorder = DiagnosticsRecorder(
            defaultRole: .sharer, deviceLabel: "test-device", enabled: true)
        DiagnosticsCenter.shared.install(recorder: recorder, environment: nil)
    }

    override func tearDown() {
        DiagnosticsCenter.shared.install(recorder: nil, environment: nil)
        super.tearDown()
    }

    private func loggedText() -> [String] {
        recorder.events().compactMap { event in
            guard case .string(let text)? = event.fields["text"] else { return nil }
            return text
        }
    }

    /// The default: the package's three dozen existing log call sites are
    /// recorded without any of them being touched. That free coverage is most
    /// of what the feature knows about node bring-up and listener binds.
    func testLinesAreTeedIntoTheRecorderByDefault() {
        PrintLogSink(prefix: "Sharer").log("bound UDP listener on 7447")

        XCTAssertEqual(loggedText(), ["bound UDP listener on 7447"])
        XCTAssertEqual(recorder.events().first?.category, .fault)
    }

    /// The opt-out keeps the line off the wire into the bundle entirely — not
    /// redacted, not fingerprinted, absent.
    func testOptedOutLinesNeverReachTheRecorder() {
        PrintLogSink(prefix: "Auth", capturesDiagnostics: false)
            .log("Signed in as Robert Andersson (robert@department.se)")

        XCTAssertTrue(recorder.events().isEmpty, "an opted-out line reached the recorder")
    }

    /// And opting out is per-sink, so one file's decision cannot silence the
    /// rest of the package.
    func testOptOutIsPerSink() {
        PrintLogSink(prefix: "Auth", capturesDiagnostics: false).log("account name here")
        PrintLogSink(prefix: "Discovery").log("found 3 peers")

        XCTAssertEqual(loggedText(), ["found 3 peers"])
    }
}
