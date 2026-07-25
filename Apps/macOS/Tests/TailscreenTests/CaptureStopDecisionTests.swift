import ScreenCaptureKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// Unit coverage for `AppState.isUserInitiatedCaptureStop(_:)`. The
/// actual `restartCapture` flow needs Screen Recording permission and
/// a live `SCStream`, neither of which we can stand up in CI — but the
/// branching decision (user-stop vs. recoverable failure) is a pure
/// function of the error and is the part we got wrong before the fix.
final class CaptureStopDecisionTests: XCTestCase {
    func testUserStoppedErrorIsUserInitiated() {
        let err = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userStopped.rawValue
        )
        XCTAssertTrue(AppState.isUserInitiatedCaptureStop(err))
    }

    func testNilErrorIsNotUserInitiated() {
        XCTAssertFalse(AppState.isUserInitiatedCaptureStop(nil))
    }

    func testDifferentSCStreamErrorIsNotUserInitiated() {
        // E.g. replayd XPC drop surfaces as a different SCStreamError code.
        // Pick any code that isn't .userStopped.
        let err = NSError(domain: SCStreamError.errorDomain, code: -3818)
        XCTAssertFalse(AppState.isUserInitiatedCaptureStop(err))
    }

    func testForeignDomainIsNotUserInitiated() {
        // An error from somewhere else with the same code value should not
        // trip the user-stopped path.
        let err = NSError(
            domain: NSPOSIXErrorDomain,
            code: SCStreamError.Code.userStopped.rawValue
        )
        XCTAssertFalse(AppState.isUserInitiatedCaptureStop(err))
    }

    // MARK: - captureStopAction routing

    func testUserStoppedRoutesToUserInitiated() {
        let err = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userStopped.rawValue
        )
        XCTAssertEqual(AppState.captureStopAction(err), .userInitiated)
    }

    func testReceiveLoopDeadRoutesToConnectionLost() {
        let err = NSError(
            domain: TailscaleScreenShareServer.receiveLoopErrorDomain, code: 1)
        XCTAssertEqual(AppState.captureStopAction(err), .connectionLost)
    }

    /// A genuine non-retryable helper *error* (slot refused, decode failure)
    /// tears the share down with an error alert — it must not loop
    /// `restartCapture()` against a wall it will keep hitting.
    func testHelperUnrecoverableRoutesToStop() {
        let err = NSError(
            domain: TailscaleScreenShareServer.helperUnrecoverableErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "replayd refused the slot"])
        XCTAssertEqual(AppState.captureStopAction(err), .helperUnrecoverable)
    }

    /// The core regression case: closing the shared window is a non-retryable
    /// stop, but an *expected* one — it routes to `.sourceClosed` (gentle
    /// notice), distinct from the error bucket, and never loops the restart.
    func testSourceGoneRoutesToSourceClosed() {
        let err = NSError(
            domain: TailscaleScreenShareServer.helperSourceGoneErrorDomain,
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "source-gone: windowNotFound"])
        XCTAssertEqual(AppState.captureStopAction(err), .sourceClosed)
    }

    func testUnknownErrorRoutesToRestart() {
        // A transient/unclassified failure still gets the one fresh-budget
        // restart attempt — we only stop outright on the terminal domains.
        let err = NSError(domain: "Tailscreen.HelperScreenCapture", code: 2)
        XCTAssertEqual(AppState.captureStopAction(err), .attemptRestart)
    }

    func testNilErrorRoutesToRestart() {
        XCTAssertEqual(AppState.captureStopAction(nil), .attemptRestart)
    }
}
