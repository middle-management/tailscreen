import XCTest

@testable import Tailscreen

/// `AppState.nodeBringUpPhase` — the mac hub's five scattered bring-up
/// signals read as the one `NodeBringUpPhase` all three hubs share.
///
/// A projection, not a stored phase (see `AppState.nodePhase`), so its
/// PRECEDENCE is the whole point: the five booleans can be read in several
/// orders, and only one order is right when two are set at once. This suite
/// pins those windows.
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

    /// The obvious precedence (in-flight before settled) is wrong here:
    /// `TailscaleAuth` sets `isAuthenticated` and clears `isLoading` from two
    /// different points in login, so there's a window where both are true.
    /// Reading in-flight first would report `startingNode` for someone
    /// already signed in.
    func testSignedInWinsOverASignInStillMarkedInFlight() {
        XCTAssertEqual(phase(isAuthenticated: true, isSigningIn: true), .ready)
    }

    /// `AppState.isLoggingIn` is set at the top of `login()`, before the auth
    /// object's `isLoading` (only once `getOrCreateNode()` returns). Reading
    /// only the latter would report `signedOut` during node creation — the
    /// slow part of a first run. The OR of the two is applied at the
    /// `nodePhase` call site (see its doc comment); this leg only pins that
    /// in-flight beats signed-out.
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

    /// An empty list before any pass has finished is "no answer yet," not "no
    /// devices" — still `discovering` even with no sweep currently running.
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

    /// Both readings satisfy `isSignedOut` but stay distinct values —
    /// collapsing them would lose the failure reason.
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
