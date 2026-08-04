import XCTest

@testable import TailscreenProtocol

/// `SharerNoticeText` — the words, and the two ways a notification daemon
/// quietly renders less than it was given.
///
/// Both gaps are silent: a daemon without `actions` DROPS the buttons rather
/// than failing the call, and one without `body` shows only the summary. Each
/// turns a working notification into one that looks fine and cannot be acted
/// on, and neither produces an error anywhere.
final class SharerNoticeTextTests: XCTestCase {

    private func notice(_ kind: SharerNoticeKind, label: String = "kestrel") -> SharerNotice {
        SharerNotice(kind: kind, identity: "100.64.0.7", label: label)
    }

    private func render(
        _ kind: SharerNoticeKind, body: Bool = true, actions: Bool = true, label: String = "kestrel"
    ) -> SharerNoticeText.Rendered {
        SharerNoticeText.render(
            notice(kind, label: label), rendersBody: body, rendersActions: actions)
    }

    // MARK: The full-capability case

    func testAnAskCarriesItsButtons() {
        let rendered = render(.viewerPending)
        XCTAssertEqual(rendered.buttons.map(\.key), ["approve", "deny"])
        XCTAssertEqual(rendered.buttons.map(\.label), ["Accept", "Deny"])
    }

    func testTheNameIsInTheBodyWhenThereIsOne() {
        let rendered = render(.viewerPending, label: "kestrel")
        XCTAssertTrue(rendered.body.contains("kestrel"), rendered.body)
        XCTAssertFalse(rendered.summary.contains("kestrel"), "the summary should not stutter")
    }

    /// A report is not an ask. Offering a choice with no consequence trains
    /// people to ignore the notifications that have one.
    func testReportsCarryNoButtons() {
        XCTAssertTrue(render(.viewerJoined).buttons.isEmpty)
        XCTAssertTrue(render(.viewerLeft).buttons.isEmpty)
    }

    /// The affirmative is worded per kind. "Accept" is right for a viewer at
    /// the gate and wrong for an invitation to start sharing, where the answer
    /// is an action rather than agreement.
    func testTheAffirmativeIsWordedPerKind() {
        XCTAssertEqual(render(.viewerPending).buttons.first?.label, "Accept")
        XCTAssertEqual(render(.controlRequested).buttons.first?.label, "Allow")
        XCTAssertEqual(render(.requestToShare).buttons.first?.label, "Share")
    }

    /// Keys cross a process boundary and come back verbatim, so they must NOT
    /// vary with the wording.
    func testKeysAreStableAcrossKinds() {
        for kind in SharerNoticeKind.allCases where !kind.actions.isEmpty {
            let keys = SharerNoticeText.buttons(for: kind).map(\.key)
            XCTAssertEqual(keys, ["approve", "deny"], "\(kind)")
        }
    }

    // MARK: No `actions` capability

    /// The buttons go, and the notice must say where to answer — otherwise it
    /// states a decision and offers no way to make it, and the person waits for
    /// something that is not coming.
    func testWithoutActionsAnAskSaysWhereToAnswer() {
        let rendered = render(.viewerPending, actions: false)
        XCTAssertTrue(rendered.buttons.isEmpty)
        XCTAssertTrue(
            rendered.body.contains(SharerNoticeText.answerInAppHint),
            "an unanswerable ask must say where to answer: \(rendered.body)")
    }

    func testWithoutActionsTheHintReachesTheSummaryToo() {
        // Body-less AND action-less: the one line has to carry everything.
        let rendered = render(.viewerPending, body: false, actions: false)
        XCTAssertTrue(rendered.body.isEmpty)
        XCTAssertTrue(rendered.summary.contains(SharerNoticeText.answerInAppHint), rendered.summary)
    }

    /// A report has nothing to answer. Telling somebody to go and answer it is
    /// how a notification becomes noise.
    func testWithoutActionsAReportGainsNoHint() {
        let rendered = render(.viewerJoined, actions: false)
        XCTAssertFalse(rendered.body.contains(SharerNoticeText.answerInAppHint), rendered.body)
    }

    /// A daemon that CAN render buttons must not also be told to go and answer
    /// somewhere else — the buttons are right there.
    func testWithActionsThereIsNoHint() {
        let rendered = render(.viewerPending, actions: true)
        XCTAssertFalse(rendered.body.contains(SharerNoticeText.answerInAppHint), rendered.body)
    }

    // MARK: No `body` capability

    /// Every notice here names a person, and the name lives in the body — so a
    /// summary-only daemon would otherwise show "Someone wants to watch" with
    /// the someone missing.
    func testWithoutABodyTheNameFoldsIntoTheSummary() {
        let rendered = render(.viewerPending, body: false, label: "kestrel")
        XCTAssertTrue(rendered.body.isEmpty)
        XCTAssertTrue(
            rendered.summary.contains("kestrel"),
            "a summary-only daemon must still name the peer: \(rendered.summary)")
    }

    /// The name goes first: a summary is truncated from the END, and the name
    /// is the part that decides whether this is worth interrupting for.
    func testWithoutABodyTheNameComesFirst() {
        let rendered = render(.viewerPending, body: false, label: "kestrel")
        XCTAssertTrue(rendered.summary.hasPrefix("kestrel"), rendered.summary)
    }

    func testEveryKindNamesThePeerWithoutABody() {
        for kind in SharerNoticeKind.allCases {
            let rendered = render(kind, body: false, label: "kestrel")
            XCTAssertTrue(
                rendered.summary.contains("kestrel"), "\(kind): \(rendered.summary)")
        }
    }

    // MARK: Withdraw

    /// A viewer admitted from the app window leaves the candidate list, and
    /// their banner must come off the screen. Leaving it there offers an
    /// Accept button that does nothing — or, on a host keyed by IP, one that
    /// lands on whoever connects next.
    func testAnIdentityThatLeftIsWithdrawn() {
        let withdraw = SharerNoticeDecision.noticesToWithdraw(
            candidates: [NoticeCandidate(identity: "b", label: "b")],
            alreadyNotified: ["a", "b"])
        XCTAssertEqual(withdraw, ["a"])
    }

    func testNothingIsWithdrawnWhileEverybodyIsStillWaiting() {
        let withdraw = SharerNoticeDecision.noticesToWithdraw(
            candidates: [
                NoticeCandidate(identity: "a", label: "a"),
                NoticeCandidate(identity: "b", label: "b"),
            ],
            alreadyNotified: ["a", "b"])
        XCTAssertTrue(withdraw.isEmpty)
    }

    /// The set that `noticesToPost` prunes is exactly the set this returns —
    /// pinned together, because a host calls both and a drift between them is
    /// either a stale banner or a withdrawn-then-reposted flicker.
    func testWithdrawAndPostAgreeOnWhatLeft() {
        let candidates = [NoticeCandidate(identity: "b", label: "b")]
        let notified: Set<String> = ["a", "b"]
        let withdraw = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: notified)
        let (_, remaining) = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending, candidates: candidates, alreadyNotified: notified)
        XCTAssertEqual(notified.subtracting(remaining), withdraw)
    }

    // MARK: - Reading an action back

    func testAnswerKeysMapToAnswers() {
        XCTAssertEqual(SharerNoticeText.action(forKey: SharerNoticeText.approveKey), .approve)
        XCTAssertEqual(SharerNoticeText.action(forKey: SharerNoticeText.denyKey), .deny)
    }

    /// The one that matters. Clicking a Windows toast's BODY activates the app
    /// carrying `openActionKey`, and a freedesktop daemon can invoke a
    /// `"default"` action nobody asked for. Reading either as a deny would
    /// decide about a peer because somebody looked at the notification.
    func testEverythingElseIsADismissalRatherThanADenial() {
        for key in [WindowsToastPayload.openActionKey, "default", "", "DENY", "approve "] {
            XCTAssertEqual(
                SharerNoticeText.action(forKey: key), .dismiss,
                "\(key) must not read as an answer")
        }
    }

    /// The keys cross a process boundary — a daemon hands them back verbatim —
    /// so a typo on either side is a button that silently does nothing.
    func testActionKeysAreDistinctFromTheOpenKey() {
        XCTAssertNotEqual(SharerNoticeText.approveKey, SharerNoticeText.denyKey)
        XCTAssertNotEqual(SharerNoticeText.approveKey, WindowsToastPayload.openActionKey)
        XCTAssertNotEqual(SharerNoticeText.denyKey, WindowsToastPayload.openActionKey)
    }
}
