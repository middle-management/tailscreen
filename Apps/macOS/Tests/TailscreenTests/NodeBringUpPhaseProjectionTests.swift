import XCTest

@testable import Tailscreen

/// `AppState.nodeBringUpPhase` — the mac hub's five scattered bring-up
/// signals read as the one `NodeBringUpPhase` all three hubs share.
///
/// The mapping is a projection rather than a stored phase (see
/// `AppState.nodePhase` for why), which makes its PRECEDENCE the entire
/// content: the same five booleans can be read in several orders and only
/// one of them is right in the windows where two are set at once. Those
/// windows are what this suite is about.
@MainActor
final class NodeBringUpPhaseProjectionTests: XCTestCase {
    /// A settled signed-in reading, for the cases that vary one input.
    private func phase(
        isAuthenticated: Bool = true,
        isSigningIn: Bool = false,
        failure: String? = nil,
        isDiscovering: Bool = false,
        hasCompletedInitialDiscovery: Bool = true
    ) -> NodeBringUpPhase {
        AppState.nodeBringUpPhase(
            isAuthenticated: isAuthenticated,
            isSigningIn: isSigningIn,
            failure: failure,
            isDiscovering: isDiscovering,
            hasCompletedInitialDiscovery: hasCompletedInitialDiscovery)
    }

    // MARK: - The ordering that matters

    /// The load-bearing leg.
    ///
    /// The obvious precedence — in-flight before settled — is wrong here.
    /// `TailscaleAuth` sets `isAuthenticated` and clears `isLoading` from
    /// two different points in the login flow, so there is a window where
    /// both are true; reading the in-flight one first reports `startingNode`
    /// for somebody already signed in and looking at their screens list,
    /// and everything gated on the phase then treats a live session as an
    /// unfinished bring-up. Checking the settled case first makes that
    /// unrepresentable rather than merely unlikely.
    func testSignedInWinsOverASignInStillMarkedInFlight() {
        XCTAssertEqual(phase(isAuthenticated: true, isSigningIn: true), .ready)
    }

    /// In-flight is BOTH login flags, and the app-level one is the earlier.
    ///
    /// `AppState.isLoggingIn` is set at the top of `login()`; the auth
    /// object's `isLoading` only once `getOrCreateNode()` has returned and
    /// the flow proper begins. Node creation is the slow part of a first
    /// run, so reading only the second leaves that entire window reporting
    /// `signedOut` — a sign-in card offering a button whose press `login()`
    /// then swallows through its own re-entrancy guard. The projection is
    /// handed the OR of the two.
    ///
    /// This leg pins only that an in-flight sign-in beats the signed-out
    /// default — the OR itself is at the `nodePhase` call site, which a test
    /// of the pure function cannot reach, and which is why the composition is
    /// spelled out in that property's doc comment rather than left to be
    /// inferred from the parameter name.
    func testASignInInFlightOutranksTheSignedOutDefault() {
        XCTAssertEqual(phase(isAuthenticated: false, isSigningIn: true), .startingNode)
    }

    /// The same rule one step further: a reason left over from an earlier
    /// attempt cannot make a signed-in hub read as failed.
    func testSignedInWinsOverALeftoverFailure() {
        XCTAssertEqual(phase(isAuthenticated: true, failure: "stale"), .ready)
    }

    /// Among the signed-out cases, a sign-in that is RUNNING outranks the
    /// failure it is retrying — otherwise pressing "Try again" leaves the
    /// reason on screen with no sign that anything is happening.
    func testARunningSignInOutranksTheFailureItRetries() {
        XCTAssertEqual(
            phase(isAuthenticated: false, isSigningIn: true, failure: "boom"), .startingNode)
    }

    // MARK: - Signed in

    func testDiscoveringWhileTheFirstPassRuns() {
        XCTAssertEqual(phase(isDiscovering: true), .discovering)
    }

    /// An empty list BEFORE any pass has finished is "no answer yet", not
    /// "no devices" — so the phase is still `discovering` even with no
    /// sweep currently running. This is the flag the loading skeleton has
    /// always keyed off; reading it here is what lets the view stop
    /// re-deriving it.
    func testNotYetAnsweredReadsAsDiscoveringEvenWithNoSweepRunning() {
        XCTAssertEqual(
            phase(isDiscovering: false, hasCompletedInitialDiscovery: false), .discovering)
    }

    func testSettledOnceAPassHasAnswered() {
        XCTAssertEqual(phase(isDiscovering: false, hasCompletedInitialDiscovery: true), .ready)
    }

    // MARK: - Signed out

    func testSigningIn() {
        XCTAssertEqual(phase(isAuthenticated: false, isSigningIn: true), .startingNode)
    }

    func testFailureCarriesItsReason() {
        XCTAssertEqual(
            phase(isAuthenticated: false, failure: "Failed to log in: no route to host"),
            .failed("Failed to log in: no route to host"))
    }

    func testNothingBroughtUp() {
        XCTAssertEqual(phase(isAuthenticated: false), .signedOut)
    }

    // MARK: - What the views read off it

    /// Both signed-out readings put the welcome pane's card in reach, which
    /// is what the shared `isSignedOut` promises and what the sign-in card
    /// relabels itself from. The two are still distinct values — collapsing
    /// them is the shortcut that loses the reason.
    func testBothSignedOutReadingsAreSignedOutButNotEqual() {
        let failed = phase(isAuthenticated: false, failure: "boom")
        let fresh = phase(isAuthenticated: false)
        XCTAssertTrue(failed.isSignedOut)
        XCTAssertTrue(fresh.isSignedOut)
        XCTAssertNotEqual(failed, fresh)
        XCTAssertTrue(failed.hasFailed)
        XCTAssertFalse(fresh.hasFailed)
    }

    /// Neither signed-in reading is signed-out — the guard that stops the
    /// hub swapping itself for the welcome pane mid-session.
    func testNeitherSignedInReadingIsSignedOut() {
        XCTAssertFalse(phase(isDiscovering: true).isSignedOut)
        XCTAssertFalse(phase().isSignedOut)
    }

    /// `startingNode` is the one phase this app renders differently from
    /// the other two hubs — a spinner on the sign-in card rather than a
    /// status pane — so it must NOT read as signed-out, or `MainWindowView`
    /// branching on that would put the hub up in the middle of a sign-in.
    func testSigningInIsNotSignedOut() {
        XCTAssertFalse(phase(isAuthenticated: false, isSigningIn: true).isSignedOut)
    }
}
