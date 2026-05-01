import XCTest
import ScreenCaptureKit
@testable import Tailscreen

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
}
