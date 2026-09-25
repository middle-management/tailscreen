import XCTest

@testable import TailscreenProtocol

/// The signed-out welcome pane's one branch: what its share-link card offers.
/// Both wrong answers are silent: offering a share on a host that can't
/// capture walks into an unprovoked refusal; missing the "sharing via link"
/// note leaves a live share with no way back to its link.
final class WelcomePaneDecisionTests: XCTestCase {
    private typealias Action = WelcomePaneDecision.LinkShareAction

    private func decide(
        canShare: Bool = true, isIdle: Bool = true, isLinkOnlyShare: Bool = false
    ) -> Action {
        WelcomePaneDecision.linkShareAction(
            canShare: canShare, isIdle: isIdle, isLinkOnlyShare: isLinkOnlyShare)
    }

    func testIdleAndCapableOffersTheShare() {
        XCTAssertEqual(decide(), .offer)
    }

    /// A host that would refuse with `.linkSharingDisabled` (no portal, no
    /// WGC, or the macOS setting off) withholds the offer rather than
    /// offering-and-refusing.
    func testAHostThatCannotShareByLinkOffersNothing() {
        XCTAssertEqual(decide(canShare: false), .unavailable)
    }

    /// A share is already up (a second would fail the share lock), so the
    /// card announces its link instead of offering to start one.
    func testALiveLinkOnlyShareIsAnnouncedInsteadOfOffered() {
        XCTAssertEqual(decide(isIdle: false, isLinkOnlyShare: true), .sharingViaLink)
    }

    /// `canShare` can go false under an already-running share (portal
    /// session revoked, display gone); the note still renders.
    func testALiveLinkOnlyShareStaysAnnouncedEvenIfCaptureIsGone() {
        XCTAssertEqual(
            decide(canShare: false, isIdle: false, isLinkOnlyShare: true), .sharingViaLink)
    }

    /// Mid-bring-up (share started, token not minted yet — `isLinkOnlyShare`
    /// still false): nothing offered (share lock would refuse a second
    /// start) and nothing announced (no link exists yet).
    func testAShareThatIsNotLinkOnlyIsNeitherOfferedNorAnnounced() {
        XCTAssertEqual(decide(isIdle: false), .unavailable)
    }

    /// Idle wins over a stale link flag.
    func testIdleBeatsALeftoverLinkFlag() {
        XCTAssertEqual(decide(isIdle: true, isLinkOnlyShare: true), .offer)
    }

    /// Idle + stale link flag + can't-share: idle is still answered first,
    /// so this is `.unavailable`, not a link note with nothing behind it.
    func testIdleWithAStaleFlagOnAHostThatCannotShareOffersNothing() {
        XCTAssertEqual(
            decide(canShare: false, isIdle: true, isLinkOnlyShare: true), .unavailable)
    }
}
