import XCTest

@testable import TailscreenProtocol

/// The one node-bring-up vocabulary the three hubs share.
///
/// Every leg here is a question two hosts previously answered differently, so
/// the suite is written as "which host was right, and why" rather than as
/// coverage of five cases.
final class NodeBringUpPhaseTests: XCTestCase {
    /// One representative of every case, for the totality legs below.
    ///
    /// Hand-written rather than `CaseIterable`, which the associated value on
    /// `failed` rules out. A case added without a line here still compiles, so
    /// the exhaustiveness legs are only as good as this list — which is why
    /// they are paired with `testEveryPhaseIsExactlyOneOfSignedOutBringingUpOrReady`,
    /// where a missed case shows up as a phase belonging to no group.
    private let allPhases: [NodeBringUpPhase] = [
        .signedOut, .startingNode, .discovering, .ready, .failed("boom")
    ]

    // MARK: - Signed out

    /// The leg the whole type exists to settle.
    ///
    /// GTK reached this state by returning to `signedOut` and hanging a note
    /// beside it; WinUI by admitting its own `failed` to `isSignedOut`. Both
    /// meant "show the sign-in pane, relabel the button", and a shared enum
    /// that dropped either reading would strand somebody on an empty screens
    /// list with no way to retry.
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

    /// A spinner is a claim that something is still happening. `failed` is the
    /// one phase where that claim is false and looks true — the app has
    /// stopped, and a spinner over it reads as a slow network rather than as
    /// an error with a button under it.
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

    /// `discovering` is emphatically not ready. Refresh, the filter menu and
    /// account switching are all gated on `isReady`, and offering Refresh
    /// against a list that is still being built restarts the very sweep the
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

    /// `hasFailed` is the replacement for the `== .failed` test that stopped
    /// compiling once the reason rode inside the case. Asserted against
    /// `failureReason` across every phase so the two can never disagree about
    /// what "failed" means — one gating a button label, the other its text.
    func testHasFailedAgreesWithFailureReasonEverywhere() {
        for phase in allPhases {
            XCTAssertEqual(
                phase.hasFailed, phase.failureReason != nil,
                "\(phase) disagrees about whether it is a failure")
        }
    }

    /// Two different failures are two different values.
    ///
    /// Load-bearing because every host publishes this through an observable
    /// slot, and several of them guard on `new != old` before republishing. If
    /// the reason were not part of identity, a second bring-up failing for a
    /// new reason would leave the first reason on screen — the stalest
    /// possible error message, describing an attempt the person has already
    /// retried past.
    func testTheReasonIsPartOfIdentity() {
        XCTAssertNotEqual(
            NodeBringUpPhase.failed("no route to control server"),
            NodeBringUpPhase.failed("auth key expired"))
        XCTAssertEqual(NodeBringUpPhase.failed("same"), NodeBringUpPhase.failed("same"))
    }

    /// A failed bring-up is NOT the signed-out state, even though both render
    /// the same pane. Collapsing them is the shortcut that loses the reason,
    /// and it is available: `isSignedOut` is true for both.
    func testFailedIsDistinctFromSignedOutDespiteRenderingTheSamePane() {
        XCTAssertNotEqual(NodeBringUpPhase.failed("boom"), .signedOut)
        XCTAssertEqual(
            NodeBringUpPhase.failed("boom").isSignedOut, NodeBringUpPhase.signedOut.isSignedOut)
    }

    // MARK: - Totality

    /// Every phase belongs to exactly one of the three groups the hub chrome
    /// branches on. A phase in none of them renders no pane at all; a phase in
    /// two renders whichever branch is tested first, which is a difference
    /// between hosts rather than a decision.
    func testEveryPhaseIsExactlyOneOfSignedOutBringingUpOrReady() {
        for phase in allPhases {
            let groups = [phase.isSignedOut, phase.isBringingUp, phase.isReady]
            XCTAssertEqual(
                groups.filter { $0 }.count, 1,
                "\(phase) belongs to \(groups.filter { $0 }.count) groups, expected exactly 1")
        }
    }
}
