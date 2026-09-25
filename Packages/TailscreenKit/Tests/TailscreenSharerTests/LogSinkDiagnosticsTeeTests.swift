import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenTransport

/// `PrintLogSink`'s tee into the diagnostics recorder, and the one call site
/// that opts out of it. The opt-out is a disclosure promise (the bundle
/// header says it carries no sign-in details), not just behavior: redaction
/// can't help here since it deliberately keeps names, and `TailscaleAuth`
/// logs the signed-in account's display name in plain prose — this flag is
/// the only thing keeping that line out of the bundle.
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

    func testLinesAreTeedIntoTheRecorderByDefault() {
        PrintLogSink(prefix: "Sharer").log("bound UDP listener on 7447")

        XCTAssertEqual(loggedText(), ["bound UDP listener on 7447"])
        XCTAssertEqual(recorder.events().first?.category, .fault)
    }

    func testOptedOutLinesNeverReachTheRecorder() {
        PrintLogSink(prefix: "Auth", capturesDiagnostics: false)
            .log("Signed in as Robert Andersson (robert@department.se)")

        XCTAssertTrue(recorder.events().isEmpty, "an opted-out line reached the recorder")
    }

    func testOptOutIsPerSink() {
        PrintLogSink(prefix: "Auth", capturesDiagnostics: false).log("account name here")
        PrintLogSink(prefix: "Discovery").log("found 3 peers")

        XCTAssertEqual(loggedText(), ["found 3 peers"])
    }
}
