import XCTest

@testable import TailscreenProtocol

final class ViewerSessionLifecycleTests: XCTestCase {
    private let tailnet = ViewerSessionTarget(
        identifier: "peer-1", host: "100.64.0.7", displayName: "Studio Mac")
    private let guest = ViewerSessionTarget(
        host: "", displayName: "Shared screen", guestToken: "tc-test-token")

    func testBeginRetainsOneReconnectTargetAndStartsConnecting() {
        var state = ViewerSessionLifecycle()

        state.begin(tailnet)

        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.target, tailnet)
        XCTAssertFalse(try XCTUnwrap(state.target).isGuest)
    }

    func testGuestTargetUsesTokenRatherThanHostOrRow() {
        var state = ViewerSessionLifecycle()

        state.begin(guest)

        XCTAssertTrue(try XCTUnwrap(state.target).isGuest)
        XCTAssertNil(state.target?.identifier)
        XCTAssertEqual(state.target?.guestToken, "tc-test-token")
    }

    func testConnectingCanMoveThroughApprovalToViewing() {
        var state = ViewerSessionLifecycle()
        let id = state.begin(tailnet)

        XCTAssertTrue(state.markAwaitingApproval(for: id))
        XCTAssertEqual(state.phase, .awaitingApproval)
        XCTAssertTrue(state.markViewing(for: id))
        XCTAssertEqual(state.phase, .viewing)
    }

    func testDirectAdmissionMovesConnectingToViewing() {
        var state = ViewerSessionLifecycle()
        let id = state.begin(tailnet)

        XCTAssertTrue(state.markViewing(for: id))
        XCTAssertEqual(state.phase, .viewing)
    }

    func testTerminalAndDismissedSessionsRejectStaleCallbacks() {
        var ended = ViewerSessionLifecycle()
        let endedID = ended.begin(tailnet)
        XCTAssertTrue(ended.end(.sharerStopped, for: endedID))
        XCTAssertFalse(ended.markAwaitingApproval(for: endedID))
        XCTAssertFalse(ended.markViewing(for: endedID))
        XCTAssertFalse(ended.fail("late", for: endedID))
        XCTAssertEqual(ended.phase, .ended(.sharerStopped))
        XCTAssertTrue(ended.isCurrent(endedID))
        XCTAssertFalse(ended.isActive(endedID))

        var dismissed = ViewerSessionLifecycle()
        let dismissedID = dismissed.begin(tailnet)
        dismissed.dismiss()
        XCTAssertFalse(dismissed.markAwaitingApproval(for: dismissedID))
        XCTAssertFalse(dismissed.markViewing(for: dismissedID))
        XCTAssertFalse(dismissed.end(.connectionLost, for: dismissedID))
        XCTAssertNil(dismissed.phase)
    }

    func testEndAndFailureStayPresentedWithReconnectTarget() {
        var ended = ViewerSessionLifecycle()
        let endedID = ended.begin(tailnet)
        XCTAssertTrue(ended.end(.disconnectedBySharer, for: endedID))
        XCTAssertTrue(try XCTUnwrap(ended.phase).isOver)
        XCTAssertEqual(ended.target, tailnet)

        var failed = ViewerSessionLifecycle()
        let failedID = failed.begin(guest)
        XCTAssertTrue(failed.fail("relay unavailable", for: failedID))
        XCTAssertTrue(try XCTUnwrap(failed.phase).isOver)
        XCTAssertEqual(failed.target, guest)
    }

    func testDismissRetainsTargetButForgetClearsIt() {
        var state = ViewerSessionLifecycle()
        state.begin(tailnet)

        state.dismiss()
        XCTAssertNil(state.phase)
        XCTAssertEqual(state.target, tailnet)

        state.forget()
        XCTAssertNil(state.phase)
        XCTAssertNil(state.target)
    }

    func testNewBeginReplacesEveryPartOfOldTarget() {
        var state = ViewerSessionLifecycle()
        let guestID = state.begin(guest)
        _ = state.fail("failed", for: guestID)

        state.begin(tailnet)

        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.target, tailnet)
        XCTAssertNil(state.target?.guestToken)
    }

    func testCallbackFromReplacedSessionCannotAdvanceNewSession() {
        var state = ViewerSessionLifecycle()
        let oldID = state.begin(guest)
        XCTAssertTrue(state.markAwaitingApproval(for: oldID))
        XCTAssertTrue(state.end(.connectionLost, for: oldID))

        let currentID = state.begin(tailnet)

        XCTAssertFalse(state.markViewing(for: oldID))
        XCTAssertFalse(state.markAwaitingApproval(for: oldID))
        XCTAssertFalse(state.end(.sharerStopped, for: oldID))
        XCTAssertFalse(state.fail("late failure", for: oldID))
        XCTAssertFalse(state.dismiss(ifCurrent: oldID))
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertTrue(state.isCurrent(currentID))
    }
}
