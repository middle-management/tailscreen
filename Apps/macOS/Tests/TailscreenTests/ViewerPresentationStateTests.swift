import XCTest

@testable import Tailscreen

@MainActor
final class ViewerPresentationStateTests: XCTestCase {
    private let target = ViewerSessionTarget(
        host: "100.64.0.7", displayName: "Studio Mac")

    func testPresentationFlagsAndPortableLifecycleMoveIndependently() {
        let state = ViewerPresentationState()
        state.begin(target: target)
        state.setAwaitingAdmission(true)

        XCTAssertEqual(state.lifecycle.phase, .connecting)
        XCTAssertEqual(state.lifecycle.target, target)
        XCTAssertTrue(state.awaitingAdmission)

        XCTAssertTrue(state.markAwaitingApproval())
        state.setAwaitingApproval(true)
        XCTAssertEqual(state.lifecycle.phase, .awaitingApproval)
        XCTAssertTrue(state.awaitingApproval)

        XCTAssertTrue(state.markViewing())
        state.setAwaitingApproval(false)
        state.setAwaitingAdmission(false)
        XCTAssertEqual(state.lifecycle.phase, .viewing)
        XCTAssertFalse(state.awaitingApproval)
        XCTAssertFalse(state.awaitingAdmission)
    }

    func testEndAndDismissKeepReconnectTarget() {
        let state = ViewerPresentationState()
        state.begin(target: target)
        _ = state.markViewing()

        state.end(.sharerStopped)
        state.setEnding(.sharerStopped)
        XCTAssertEqual(state.lifecycle.phase, .ended(.sharerStopped))
        XCTAssertEqual(state.ending, .sharerStopped)

        state.dismiss()
        state.setEnding(nil)
        XCTAssertNil(state.lifecycle.phase)
        XCTAssertNil(state.ending)
        XCTAssertEqual(state.lifecycle.target, target)
    }

    func testNewTailnetSessionClearsGuestIdentityAsOneTargetReplacement() {
        let state = ViewerPresentationState()
        state.begin(
            target: ViewerSessionTarget(
                host: "", displayName: "Shared screen", guestToken: "tc-token"))
        state.setGuestSession(true)
        XCTAssertTrue(state.lifecycle.target?.isGuest == true)
        XCTAssertTrue(state.isGuestSession)

        state.begin(target: target)
        state.setGuestSession(false)
        XCTAssertEqual(state.lifecycle.target, target)
        XCTAssertNil(state.lifecycle.target?.guestToken)
        XCTAssertFalse(state.isGuestSession)
    }
}
