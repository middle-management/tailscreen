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
        state.begin(tailnet)

        XCTAssertTrue(state.markAwaitingApproval())
        XCTAssertEqual(state.phase, .awaitingApproval)
        XCTAssertTrue(state.markViewing())
        XCTAssertEqual(state.phase, .viewing)
    }

    func testDirectAdmissionMovesConnectingToViewing() {
        var state = ViewerSessionLifecycle()
        state.begin(tailnet)

        XCTAssertTrue(state.markViewing())
        XCTAssertEqual(state.phase, .viewing)
    }

    func testTerminalAndDismissedSessionsRejectStaleCallbacks() {
        var ended = ViewerSessionLifecycle()
        ended.begin(tailnet)
        XCTAssertTrue(ended.end(.sharerStopped))
        XCTAssertFalse(ended.markAwaitingApproval())
        XCTAssertFalse(ended.markViewing())
        XCTAssertFalse(ended.fail("late"))
        XCTAssertEqual(ended.phase, .ended(.sharerStopped))

        var dismissed = ViewerSessionLifecycle()
        dismissed.begin(tailnet)
        dismissed.dismiss()
        XCTAssertFalse(dismissed.markAwaitingApproval())
        XCTAssertFalse(dismissed.markViewing())
        XCTAssertFalse(dismissed.end(.connectionLost))
        XCTAssertNil(dismissed.phase)
    }

    func testEndAndFailureStayPresentedWithReconnectTarget() {
        var ended = ViewerSessionLifecycle()
        ended.begin(tailnet)
        XCTAssertTrue(ended.end(.disconnectedBySharer))
        XCTAssertTrue(try XCTUnwrap(ended.phase).isOver)
        XCTAssertEqual(ended.target, tailnet)

        var failed = ViewerSessionLifecycle()
        failed.begin(guest)
        XCTAssertTrue(failed.fail("relay unavailable"))
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
        state.begin(guest)
        _ = state.fail("failed")

        state.begin(tailnet)

        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.target, tailnet)
        XCTAssertNil(state.target?.guestToken)
    }
}
