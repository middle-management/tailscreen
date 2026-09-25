import XCTest

@testable import TailscreenProtocol

/// `ShareBringUpPhase` — the one sharer lifecycle the three hosts share.
final class ShareBringUpPhaseTests: XCTestCase {
    private let allPhases: [ShareBringUpPhase] = [.idle, .starting, .sharing, .failed("boom")]

    /// `starting` is a state of its own, distinct from both ends of it — a
    /// host that folds it into either neighbour (e.g. WinUI's old `isSharing`-only
    /// model, whose card read "Not sharing" through bring-up) satisfies everything else here.
    func testStartingIsNeitherIdleNorSharing() {
        XCTAssertNotEqual(ShareBringUpPhase.starting, .idle)
        XCTAssertNotEqual(ShareBringUpPhase.starting, .sharing)
        XCTAssertFalse(ShareBringUpPhase.starting.isSharing)
    }

    /// Start is offered from idle AND from a failure — the way out of a failed
    /// start is the button that tried it. Gate on `canStart`, never `== .idle`,
    /// or a `failed` phase silently loses its retry.
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

    /// `isLive` is the question "is anything running" gates actually ask, and
    /// it is not `!= .idle` — a `failed` phase has torn down completely but
    /// would read as live under that gate.
    func testOnlyStartingAndSharingAreLive() {
        XCTAssertTrue(ShareBringUpPhase.starting.isLive)
        XCTAssertTrue(ShareBringUpPhase.sharing.isLive)
        XCTAssertFalse(ShareBringUpPhase.idle.isLive)
        XCTAssertFalse(ShareBringUpPhase.failed("boom").isLive)
    }

    /// A phase you can start from is exactly a phase with nothing running.
    func testIsLiveIsTheExactComplementOfCanStart() {
        for phase in allPhases {
            XCTAssertEqual(phase.isLive, !phase.canStart, "\(phase)")
        }
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

    /// Two different failures are two different values — hosts guard on
    /// `new != old`, so a new reason must not be swallowed as "no change".
    func testTheReasonIsPartOfIdentity() {
        XCTAssertNotEqual(
            ShareBringUpPhase.failed("Tailscale isn't up yet"),
            ShareBringUpPhase.failed("could not describe the display to capture"))
    }

    /// Idle and failed both offer Start but stay distinct values.
    func testIdleAndFailedBothStartButAreNotEqual() {
        XCTAssertEqual(ShareBringUpPhase.idle.canStart, ShareBringUpPhase.failed("x").canStart)
        XCTAssertNotEqual(ShareBringUpPhase.idle, .failed("x"))
    }
}
