import XCTest

@testable import TailscreenProtocol

/// `ShareBringUpPhase` — the one sharer lifecycle the three hosts share.
///
/// Shorter than its siblings' suites because the enum is simpler, but the
/// two legs that matter are the two that were WRONG somewhere before it
/// existed: a host with no `starting` case, and a gate written as
/// `== .idle` that a `failed` case silently locks out.
final class ShareBringUpPhaseTests: XCTestCase {
    private let allPhases: [ShareBringUpPhase] = [.idle, .starting, .sharing, .failed("boom")]

    /// `starting` is a state of its own, distinct from both ends of it.
    ///
    /// The WinUI engine had only `isSharing`, so bring-up was
    /// indistinguishable from idle and its card said "Not sharing" through
    /// the whole of it. Asserting the inequalities is the point: a host that
    /// folds `starting` into either neighbour satisfies everything else here.
    func testStartingIsNeitherIdleNorSharing() {
        XCTAssertNotEqual(ShareBringUpPhase.starting, .idle)
        XCTAssertNotEqual(ShareBringUpPhase.starting, .sharing)
        XCTAssertFalse(ShareBringUpPhase.starting.isSharing)
    }

    /// The other one that was wrong somewhere.
    ///
    /// Start is offered from idle AND from a failure — the way out of a
    /// failed start is the button that tried it. A gate spelled `== .idle`
    /// reads correctly and quietly removes the retry, which is exactly the
    /// bug `NodeBringUpPhase` introduced on the GTK link-share gate and that
    /// had to be caught by hand.
    func testStartIsOfferedFromIdleAndFromAFailure() {
        XCTAssertTrue(ShareBringUpPhase.idle.canStart)
        XCTAssertTrue(ShareBringUpPhase.failed("no capture backend").canStart)
    }

    func testStartIsNotOfferedWhileStartingOrLive() {
        XCTAssertFalse(ShareBringUpPhase.starting.canStart)
        XCTAssertFalse(ShareBringUpPhase.sharing.canStart)
    }

    func testOnlySharingIsLive() {
        for phase in allPhases where phase != .sharing {
            XCTAssertFalse(phase.isSharing, "\(phase) must not read as live")
        }
        XCTAssertTrue(ShareBringUpPhase.sharing.isSharing)
    }

    func testFailureCarriesItsReason() {
        XCTAssertEqual(
            ShareBringUpPhase.failed("this session cannot share a single window").failureReason,
            "this session cannot share a single window")
    }

    func testOnlyFailedCarriesAReason() {
        XCTAssertNil(ShareBringUpPhase.idle.failureReason)
        XCTAssertNil(ShareBringUpPhase.starting.failureReason)
        XCTAssertNil(ShareBringUpPhase.sharing.failureReason)
    }

    func testHasFailedAgreesWithFailureReasonEverywhere() {
        for phase in allPhases {
            XCTAssertEqual(
                phase.hasFailed, phase.failureReason != nil,
                "\(phase) disagrees about whether it is a failure")
        }
    }

    /// Two different failures are two different values — every host
    /// publishes this through an observable slot and several guard on
    /// `new != old`, so a second failure for a new reason must replace the
    /// first rather than be swallowed as "no change".
    func testTheReasonIsPartOfIdentity() {
        XCTAssertNotEqual(
            ShareBringUpPhase.failed("Tailscale isn't up yet"),
            ShareBringUpPhase.failed("could not describe the display to capture"))
    }

    /// Idle and failed both offer Start and are still distinct values —
    /// collapsing them is the shortcut that loses the reason.
    func testIdleAndFailedBothStartButAreNotEqual() {
        XCTAssertEqual(ShareBringUpPhase.idle.canStart, ShareBringUpPhase.failed("x").canStart)
        XCTAssertNotEqual(ShareBringUpPhase.idle, .failed("x"))
    }
}
