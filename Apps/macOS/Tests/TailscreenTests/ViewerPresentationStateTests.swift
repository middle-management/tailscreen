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

    /// A failure is its own thing, not an end reason.
    ///
    /// This used to project `.connectionLost`, because the in-window pane had
    /// no way to say anything else — so a dial that was refused, or a token
    /// that had expired, told the person "The connection to X was lost",
    /// describing a session they never had. `failureMessage` carries the real
    /// sentence and `ending` stays nil.
    func testFailureIsNotAnEndReason() {
        let state = ViewerPresentationState()
        let id = state.begin(target: target)

        XCTAssertTrue(state.fail("dial failed", for: id))

        XCTAssertEqual(state.lifecycle.phase, .failed("dial failed"))
        XCTAssertNil(state.ending)
        XCTAssertEqual(state.failureMessage, "dial failed")
    }

    /// Both terminal phases keep the pane up, which is what the menu gates
    /// and the window handling actually ask. Splitting `ending` from
    /// `failureMessage` must not cost them that answer — testing
    /// `ending != nil` would now be false for a failure and let ⌘W and the
    /// reconnect path treat a failed session as if nothing were on screen.
    func testBothTerminalPhasesReadAsOver() {
        let ended = ViewerPresentationState()
        let endedID = ended.begin(target: target)
        XCTAssertTrue(ended.end(.sharerStopped, for: endedID))
        XCTAssertTrue(ended.isOver)

        let failed = ViewerPresentationState()
        let failedID = failed.begin(target: target)
        XCTAssertTrue(failed.fail("dial failed", for: failedID))
        XCTAssertTrue(failed.isOver)
    }

    /// The placard covers the two pre-video phases and nothing else. The
    /// `connecting` half is new: it is the phase every session passes
    /// through, and this app used to show nothing for it.
    func testPlacardCoversConnectingAndAwaitingApprovalOnly() {
        let state = ViewerPresentationState()
        let id = state.begin(target: target)
        XCTAssertEqual(state.placardPhase, .connecting)

        XCTAssertTrue(state.markAwaitingApproval(for: id))
        XCTAssertEqual(state.placardPhase, .awaitingApproval)

        XCTAssertTrue(state.markViewing(for: id))
        XCTAssertNil(state.placardPhase, "video is up — the placard must be gone")

        XCTAssertTrue(state.end(.sharerStopped, for: id))
        XCTAssertNil(state.placardPhase, "the terminal pane owns this, not the placard")
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
