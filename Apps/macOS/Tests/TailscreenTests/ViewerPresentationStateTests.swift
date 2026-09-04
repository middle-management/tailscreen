import Combine
import XCTest

@testable import Tailscreen

@MainActor
final class ViewerPresentationStateTests: XCTestCase {
    private let target = ViewerSessionTarget(
        host: "100.64.0.7", displayName: "Studio Mac")

    func testLifecycleDerivesApprovalWhileAdmissionRemainsMacSpecific() {
        let state = ViewerPresentationState()
        let id = state.begin(target: target)
        state.setAwaitingAdmission(true)

        XCTAssertEqual(state.lifecycle.phase, .connecting)
        XCTAssertEqual(state.lifecycle.target, target)
        XCTAssertTrue(state.awaitingAdmission)

        XCTAssertTrue(state.markAwaitingApproval(for: id))
        XCTAssertEqual(state.lifecycle.phase, .awaitingApproval)
        XCTAssertTrue(state.awaitingApproval)

        XCTAssertTrue(state.markViewing(for: id))
        state.setAwaitingAdmission(false)
        XCTAssertEqual(state.lifecycle.phase, .viewing)
        XCTAssertFalse(state.awaitingApproval)
        XCTAssertFalse(state.awaitingAdmission)
    }

    func testEndAndDismissKeepReconnectTarget() {
        let state = ViewerPresentationState()
        let id = state.begin(target: target)
        _ = state.markViewing(for: id)

        state.end(.sharerStopped, for: id)
        XCTAssertEqual(state.lifecycle.phase, .ended(.sharerStopped))
        XCTAssertEqual(state.ending, .sharerStopped)

        state.dismiss()
        XCTAssertNil(state.lifecycle.phase)
        XCTAssertNil(state.ending)
        XCTAssertEqual(state.lifecycle.target, target)
    }

    func testNewTailnetSessionClearsGuestIdentityAsOneTargetReplacement() {
        let state = ViewerPresentationState()
        state.begin(
            target: ViewerSessionTarget(
                host: "", displayName: "Shared screen", guestToken: "tc-token"))
        XCTAssertTrue(state.lifecycle.target?.isGuest == true)
        XCTAssertTrue(state.isGuestSession)

        state.begin(target: target)
        XCTAssertEqual(state.lifecycle.target, target)
        XCTAssertNil(state.lifecycle.target?.guestToken)
        XCTAssertFalse(state.isGuestSession)
    }

    func testFailureProjectsConnectionLostWithoutParallelEndingState() {
        let state = ViewerPresentationState()
        let id = state.begin(target: target)

        XCTAssertTrue(state.fail("dial failed", for: id))

        XCTAssertEqual(state.lifecycle.phase, .failed("dial failed"))
        XCTAssertEqual(state.ending, .connectionLost)
    }

    func testLifecycleMutationPublishesObjectChange() {
        let state = ViewerPresentationState()
        var changeCount = 0
        let observation = state.objectWillChange.sink { changeCount += 1 }

        let id = state.begin(target: target)
        XCTAssertGreaterThan(changeCount, 0)
        let changesAfterBegin = changeCount

        XCTAssertTrue(state.markViewing(for: id))
        XCTAssertGreaterThan(changeCount, changesAfterBegin)
        withExtendedLifetime(observation) {}
    }
}
