import XCTest

@testable import Tailscreen

/// Unit tests for the `AppError` user-facing error model: identity-based
/// equality, the Copy Details payload, and the stability of the `TS-…`
/// codes the constructors mint (they're pasted into bug reports, so a
/// silent renumber is a regression).
final class AppErrorTests: XCTestCase {

    private struct MarkerError: LocalizedError {
        var errorDescription: String? { "marker failure" }
    }

    func testEqualityIsByInstanceNotContent() {
        let a = AppError.legacy(title: "T", message: "M")
        let b = AppError.legacy(title: "T", message: "M")
        // Two alerts with identical content are still distinct alerts —
        // equality is the `id`, so SwiftUI can present the same message
        // twice in a row.
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a)
    }

    func testCopyableDetailsIncludesUnderlyingOnlyWhenPresent() {
        let plain = AppError.legacy(title: "Title", message: "Message")
        let plainDetails = plain.copyableDetails()
        XCTAssertTrue(plainDetails.contains("Code: TS-GENERIC-001"))
        XCTAssertTrue(plainDetails.contains("Title: Title"))
        XCTAssertTrue(plainDetails.contains("Message: Message"))
        XCTAssertFalse(plainDetails.contains("Underlying:"))

        let wrapped = AppError.screenCaptureGeneric(MarkerError())
        let wrappedDetails = wrapped.copyableDetails()
        XCTAssertTrue(wrappedDetails.contains("Underlying:"))
        XCTAssertTrue(wrappedDetails.contains("MarkerError"))
    }

    func testConstructorCodesAreStable() {
        let underlying = MarkerError()
        let expectations: [(AppError, String)] = [
            (.screenCaptureStartTimeout(), "TS-SCREEN-002"),
            (.screenCaptureBundlePoisoned(), "TS-SCREEN-003"),
            (.screenCaptureNoFrames(), "TS-SCREEN-004"),
            (.screenCaptureGeneric(underlying), "TS-SCREEN-099"),
            (.connectionFailed(host: "wisp-2", underlying: underlying), "TS-NET-001"),
            (.discoveryFailed(underlying), "TS-NET-002"),
            (.discoveryUnauthenticated(), "TS-NET-003"),
            (.requestToShareFailed(peer: "wisp-2", underlying: underlying), "TS-NET-004"),
            (.voiceInitFailed(underlying), "TS-VOICE-001"),
            (.voiceViewerInitFailed(underlying), "TS-VOICE-002"),
            (.voiceNotReady(), "TS-VOICE-003"),
            (.microphoneUnavailable(underlying), "TS-VOICE-004"),
            (.loginFailed(underlying), "TS-AUTH-001"),
            (.signOutFailed(underlying), "TS-AUTH-002"),
            (.sharingGeneric(underlying), "TS-SCREEN-100"),
            (.legacy(title: "t", message: "m"), "TS-GENERIC-001")
        ]
        for (error, code) in expectations {
            XCTAssertEqual(error.code, code)
            XCTAssertFalse(error.title.isEmpty, "\(code) has an empty title")
            XCTAssertFalse(error.message.isEmpty, "\(code) has an empty message")
        }
    }

    func testInterpolatingConstructorsCarryTheDetail() {
        let err = AppError.connectionFailed(host: "wisp-2", underlying: MarkerError())
        XCTAssertTrue(err.message.contains("wisp-2"))
        XCTAssertTrue(err.message.contains("marker failure"))
        XCTAssertEqual(err.underlying, String(describing: MarkerError()))
    }

    func testPermissionErrorsOfferAnAction() {
        // The two errors whose fix lives in System Settings must carry an
        // inline action button; pure-informational ones must not.
        XCTAssertNotNil(AppError.screenCaptureStartTimeout().action)
        XCTAssertNotNil(AppError.microphoneUnavailable(MarkerError()).action)
        XCTAssertNil(AppError.screenCaptureBundlePoisoned().action)
        XCTAssertNil(AppError.voiceNotReady().action)
    }
}
