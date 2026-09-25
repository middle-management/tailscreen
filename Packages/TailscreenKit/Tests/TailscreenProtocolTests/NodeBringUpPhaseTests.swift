import XCTest

@testable import TailscreenProtocol

/// The one node-bring-up vocabulary the three hubs share.
///
/// Every leg here is a question two hosts previously answered differently, so
/// the suite is written as "which host was right, and why" rather than as
/// coverage of five cases.
final class NodeBringUpPhaseTests: XCTestCase {
    /// One representative of every case, for the totality legs below.
    /// Hand-written rather than `CaseIterable`, which `failed`'s associated
    /// value rules out. A case added without a line here is invisible to
    /// this file, but every derived property switches exhaustively, so
    /// adding a case fails the build until each has an answer.
    private let allPhases: [NodeBringUpPhase] = [
        .signedOut, .startingNode, .discovering, .ready, .failed("boom")
    ]

    // MARK: - Signed out

    /// A shared enum that dropped this reading would strand somebody on an
    /// empty screens list with no way to retry.
    func testFailedIsSignedOutSoTheRetryButtonIsStillReachable() {
        XCTAssertTrue(NodeBringUpPhase.failed("could not start Tailscale").isSignedOut)
        XCTAssertTrue(NodeBringUpPhase.signedOut.isSignedOut)
    }

    func testBringUpAndReadyAreNotSignedOut() {
        XCTAssertFalse(NodeBringUpPhase.startingNode.isSignedOut)
        XCTAssertFalse(NodeBringUpPhase.discovering.isSignedOut)
        XCTAssertFalse(NodeBringUpPhase.ready.isSignedOut)
    }

    // MARK: - Spinner

    /// A spinner over a stopped app reads as a slow network, not an error
    /// with a button under it.
    func testFailedDoesNotSpin() {
        XCTAssertFalse(NodeBringUpPhase.failed("boom").isBringingUp)
    }

    func testOnlyTheTwoInFlightPhasesSpin() {
        XCTAssertTrue(NodeBringUpPhase.startingNode.isBringingUp)
        XCTAssertTrue(NodeBringUpPhase.discovering.isBringingUp)
        XCTAssertFalse(NodeBringUpPhase.signedOut.isBringingUp)
        XCTAssertFalse(NodeBringUpPhase.ready.isBringingUp)
    }

    // MARK: - Ready

    /// Refresh, the filter menu and account switching are gated on
    /// `isReady` — offering Refresh mid-discovery restarts the sweep the
    /// person is waiting on.
    func testDiscoveringIsNotReady() {
        XCTAssertFalse(NodeBringUpPhase.discovering.isReady)
    }

    func testReadyIsTheOnlySettledPhase() {
        XCTAssertTrue(NodeBringUpPhase.ready.isReady)
        for phase in allPhases where phase != .ready {
            XCTAssertFalse(phase.isReady, "\(phase) must not read as settled")
        }
    }

    // MARK: - Failure reason

    func testFailureReasonRoundTrips() {
        XCTAssertEqual(
            NodeBringUpPhase.failed("Could not start Tailscale: timed out").failureReason,
            "Could not start Tailscale: timed out")
    }

    func testOnlyFailedCarriesAReason() {
        XCTAssertNil(NodeBringUpPhase.signedOut.failureReason)
        XCTAssertNil(NodeBringUpPhase.startingNode.failureReason)
        XCTAssertNil(NodeBringUpPhase.discovering.failureReason)
        XCTAssertNil(NodeBringUpPhase.ready.failureReason)
    }

    /// Asserted across every phase so `hasFailed` and `failureReason` can
    /// never disagree about what "failed" means.
    func testHasFailedAgreesWithFailureReasonEverywhere() {
        for phase in allPhases {
            XCTAssertEqual(
                phase.hasFailed, phase.failureReason != nil,
                "\(phase) disagrees about whether it is a failure")
        }
    }

    /// Load-bearing because hosts guard on `new != old` before republishing
    /// — if the reason weren't part of identity, a second failure with a new
    /// reason would leave the stale first reason on screen.
    func testTheReasonIsPartOfIdentity() {
        XCTAssertNotEqual(
            NodeBringUpPhase.failed("no route to control server"),
            NodeBringUpPhase.failed("auth key expired"))
        XCTAssertEqual(NodeBringUpPhase.failed("same"), NodeBringUpPhase.failed("same"))
    }

    /// A failed bring-up is NOT the signed-out state, even though both
    /// render the same pane and `isSignedOut` is true for both.
    func testFailedIsDistinctFromSignedOutDespiteRenderingTheSamePane() {
        XCTAssertNotEqual(NodeBringUpPhase.failed("boom"), .signedOut)
        XCTAssertEqual(
            NodeBringUpPhase.failed("boom").isSignedOut, NodeBringUpPhase.signedOut.isSignedOut)
    }

    // MARK: - Totality

    /// A phase in none of the three groups renders no pane; a phase in two
    /// renders whichever branch is tested first — a difference between
    /// hosts, not a decision.
    func testEveryPhaseIsExactlyOneOfSignedOutBringingUpOrReady() {
        for phase in allPhases {
            let groups = [phase.isSignedOut, phase.isBringingUp, phase.isReady]
            XCTAssertEqual(
                groups.filter { $0 }.count, 1,
                "\(phase) belongs to \(groups.filter { $0 }.count) groups, expected exactly 1")
        }
    }
}
