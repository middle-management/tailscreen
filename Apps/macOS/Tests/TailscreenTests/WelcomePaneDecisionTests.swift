import XCTest

@testable import Tailscreen

/// Unit tests for `AppState.welcomeLinkShareAction` — the three-way branch
/// the signed-out welcome pane's share-link card renders.
///
/// Worth pinning because two of the three cases are only reachable in
/// states a screenshot of the pane never shows: link sharing turned off in
/// Settings, and a link-only share already running while the window sits on
/// the signed-out pane (which is where it stays — a guest-only share needs
/// no sign-in, so the hub never appears). The failure in both directions is
/// silent: offer a button whose picker will refuse (`.linkSharingDisabled`)
/// and the person meets an error they were invited into; drop the note and
/// a running share loses the only line saying where its link lives.
@MainActor
final class WelcomePaneDecisionTests: XCTestCase {
    func testIdleWithLinkSharingOnOffersToShare() {
        XCTAssertEqual(
            AppState.welcomeLinkShareAction(
                linkSharingEnabled: true, sharingState: .idle, isGuestOnlyShare: false),
            .offer)
    }

    func testLinkSharingOffOffersNothing() {
        // The picker would land in `startSharing`'s `guestOnly &&
        // !linkSharingEnabled` refusal, so the button must not be there.
        XCTAssertEqual(
            AppState.welcomeLinkShareAction(
                linkSharingEnabled: false, sharingState: .idle, isGuestOnlyShare: false),
            .unavailable)
    }

    func testShareStartingOffersNothing() {
        // A second picker mid-bring-up only fails the share lock.
        XCTAssertEqual(
            AppState.welcomeLinkShareAction(
                linkSharingEnabled: true, sharingState: .starting, isGuestOnlyShare: false),
            .unavailable)
    }

    func testLiveGuestOnlyShareShowsTheMenubarNote() {
        XCTAssertEqual(
            AppState.welcomeLinkShareAction(
                linkSharingEnabled: true, sharingState: .active, isGuestOnlyShare: true),
            .sharingViaLink)
    }

    /// The asymmetric case, and the reason the branch is ordered rather
    /// than a lookup: a guest-only share stays announced even after the
    /// feature gate is switched off underneath it. Turning the setting off
    /// does not stop a running share, and a share whose link the person
    /// cannot find is one they cannot hand to anybody or reason about.
    func testGuestOnlyShareStillAnnouncedAfterLinkSharingIsTurnedOff() {
        XCTAssertEqual(
            AppState.welcomeLinkShareAction(
                linkSharingEnabled: false, sharingState: .active, isGuestOnlyShare: true),
            .sharingViaLink)
    }

    /// A tailnet share cannot be running while this pane is on screen, but
    /// the flags are three independent `@Published` values and nothing in
    /// the type system says so — so pin that the note is keyed on
    /// `isGuestOnlyShare` rather than on "a share is active", which would
    /// point at a menubar link that does not exist.
    func testActiveShareThatIsNotGuestOnlyOffersNothing() {
        XCTAssertEqual(
            AppState.welcomeLinkShareAction(
                linkSharingEnabled: true, sharingState: .active, isGuestOnlyShare: false),
            .unavailable)
    }
}
