import XCTest

@testable import TailscreenProtocol

/// The signed-out welcome pane's one branch: what its share-link card offers
/// for the sharing half of the feature.
///
/// Worth a suite because both wrong answers are silent. An offered "Share
/// your screen via Link…" on a host that cannot capture walks somebody into a
/// refusal they did not provoke; a missing "you're sharing via link" note
/// leaves a live share with nothing on screen saying where its link is — on
/// the two hosts whose window is the only surface, that is a share the person
/// can neither hand out nor find their way back to.
final class WelcomePaneDecisionTests: XCTestCase {
    private typealias Action = WelcomePaneDecision.LinkShareAction

    private func decide(
        canShare: Bool = true, isIdle: Bool = true, isLinkOnlyShare: Bool = false
    ) -> Action {
        WelcomePaneDecision.linkShareAction(
            canShare: canShare, isIdle: isIdle, isLinkOnlyShare: isLinkOnlyShare)
    }

    /// The ordinary case, and the only one a screenshot ever shows: signed
    /// out, nothing running, a machine that can capture.
    func testIdleAndCapableOffersTheShare() {
        XCTAssertEqual(decide(), .offer)
    }

    /// A Wayland session with no portal, a Windows build without
    /// Windows.Graphics.Capture, or — on macOS, whose gate is a setting
    /// rather than a backend — link sharing switched off, where the picker
    /// would refuse with `.linkSharingDisabled`. Withheld rather than
    /// offered-and-refused in all three: finding out by pressing the button
    /// is the failure this prevents.
    func testAHostThatCannotShareByLinkOffersNothing() {
        XCTAssertEqual(decide(canShare: false), .unavailable)
    }

    /// A share is up. The button would start a second one against a share
    /// lock that will refuse it, so what the card owes the person is where
    /// the running one's link is.
    func testALiveLinkOnlyShareIsAnnouncedInsteadOfOffered() {
        XCTAssertEqual(decide(isIdle: false, isLinkOnlyShare: true), .sharingViaLink)
    }

    /// The asymmetric case, and the reason the branch is ordered rather than
    /// a lookup: the capture answer can go false under a share that is
    /// already running (a portal session revoked, a display gone). The note
    /// still renders — the share exists whatever the host could start now.
    func testALiveLinkOnlyShareStaysAnnouncedEvenIfCaptureIsGone() {
        XCTAssertEqual(
            decide(canShare: false, isIdle: false, isLinkOnlyShare: true), .sharingViaLink)
    }

    /// Mid-bring-up — the share has begun but its token does not exist yet,
    /// so `isLinkOnlyShare` is false for the moment. Nothing is offered,
    /// because a second start would fail the share lock, and nothing is
    /// announced, because there is no link to announce.
    ///
    /// Same tuple, second reading: a share running that is NOT link-only.
    /// No host can reach that with this pane on screen — a tailnet share
    /// means a signed-in hub — but the three flags are independent
    /// published values and nothing in the type system says so, so this
    /// also pins that the note is keyed on the link, not on "a share is
    /// running", which would point at a link that does not exist.
    func testAShareThatIsNotLinkOnlyIsNeitherOfferedNorAnnounced() {
        XCTAssertEqual(decide(isIdle: false), .unavailable)
    }

    /// Idle wins over a stale link flag. A `.offer` here is not a fallback:
    /// this state is reachable only if a host publishes idle while still
    /// claiming a link, and starting a share is the right answer to a person
    /// looking at an idle card.
    func testIdleBeatsALeftoverLinkFlag() {
        XCTAssertEqual(decide(isIdle: true, isLinkOnlyShare: true), .offer)
    }
}
