import XCTest

@testable import TailscreenProtocol

/// `SharerNoticeDecision` — when to interrupt the sharer, and about whom.
/// Both failure directions are invisible in normal use and produce no error:
/// under-notifying strands a viewer at an approval gate; over-notifying
/// trains the sharer to swipe banners away, stranding the next one too.
final class SharerNoticeTests: XCTestCase {

    private func candidates(_ pairs: (String, String)...) -> [NoticeCandidate] {
        pairs.map { NoticeCandidate(identity: $0.0, label: $0.1) }
    }

    // MARK: - First arrivals

    func testFirstArrivalIsPosted() {
        let result = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: [])

        XCTAssertEqual(result.post.count, 1)
        XCTAssertEqual(result.post.first?.label, "wisp")
        XCTAssertEqual(result.post.first?.kind, .viewerPending)
        XCTAssertEqual(result.notified, ["100.64.0.1"])
    }

    /// The core anti-spam rule: whole-list snapshots get re-emitted for
    /// reasons unrelated to a given peer (hostname resolving, another row
    /// changing), so re-announcing on each would make notices useless.
    func testResendingTheSameSnapshotPostsNothing() {
        let rows = candidates(("100.64.0.1", "wisp"), ("100.64.0.2", "ember"))
        let first = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending, candidates: rows, alreadyNotified: [])
        XCTAssertEqual(first.post.count, 2)

        let second = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending, candidates: rows, alreadyNotified: first.notified)
        XCTAssertTrue(second.post.isEmpty)
        XCTAssertEqual(second.notified, first.notified)
    }

    /// Same peer, better name (hostname resolving), no second banner.
    func testLabelChangeAloneDoesNotRepost() {
        let first = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending,
            candidates: candidates(("100.64.0.1", "100.64.0.1")),
            alreadyNotified: [])
        XCTAssertEqual(first.post.count, 1)

        let second = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: first.notified)
        XCTAssertTrue(second.post.isEmpty)
    }

    func testOnlyTheNewRowIsPosted() {
        let first = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: [])

        let second = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested,
            candidates: candidates(("100.64.0.1", "wisp"), ("100.64.0.2", "ember")),
            alreadyNotified: first.notified)

        XCTAssertEqual(second.post.map(\.label), ["ember"])
    }

    // MARK: - Forget-on-leave

    /// A peer that gives up and genuinely asks again must be announced
    /// again — without the prune, one denied request silences it for good.
    func testLeavingAndReturningPostsAgain() {
        let first = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: [])

        let empty = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested, candidates: [], alreadyNotified: first.notified)
        XCTAssertTrue(empty.post.isEmpty)
        XCTAssertTrue(empty.notified.isEmpty, "a departed identity must be forgotten")

        let again = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: empty.notified)
        XCTAssertEqual(again.post.count, 1)
    }

    func testPruningOneIdentityKeepsTheOthersSuppressed() {
        let first = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending,
            candidates: candidates(("a", "wisp"), ("b", "ember")),
            alreadyNotified: [])

        let second = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending,
            candidates: candidates(("a", "wisp")),
            alreadyNotified: first.notified)

        XCTAssertTrue(second.post.isEmpty)
        XCTAssertEqual(second.notified, ["a"])
    }

    // MARK: - Shape

    /// Kinds share one notified-set, so their ids must not collide.
    func testIDsAreDistinctAcrossKindsForOneIdentity() {
        let pending = SharerNotice(kind: .viewerPending, identity: "100.64.0.1", label: "wisp")
        let control = SharerNotice(kind: .controlRequested, identity: "100.64.0.1", label: "wisp")
        XCTAssertNotEqual(pending.id, control.id)
    }

    func testPostOrderFollowsCandidateOrder() {
        let result = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending,
            candidates: candidates(("a", "one"), ("b", "two"), ("c", "three")),
            alreadyNotified: [])
        XCTAssertEqual(result.post.map(\.label), ["one", "two", "three"])
    }

    func testEmptyCandidatesClearTheNotifiedSet() {
        let result = SharerNoticeDecision.noticesToPost(
            kind: .viewerJoined, candidates: [], alreadyNotified: ["a", "b"])
        XCTAssertTrue(result.post.isEmpty)
        XCTAssertTrue(result.notified.isEmpty)
    }

    // MARK: - Actions and urgency

    func testOnlyTheAsksAreActionable() {
        XCTAssertEqual(SharerNoticeKind.viewerPending.actions, [.approve, .deny])
        XCTAssertEqual(SharerNoticeKind.controlRequested.actions, [.approve, .deny])
        XCTAssertEqual(SharerNoticeKind.requestToShare.actions, [.approve, .deny])
        XCTAssertTrue(SharerNoticeKind.viewerJoined.actions.isEmpty)
        XCTAssertTrue(SharerNoticeKind.viewerLeft.actions.isEmpty)
    }

    /// Drives each platform's break-through-Focus level.
    func testOnlyMidSessionAsksBlockSomeone() {
        XCTAssertTrue(SharerNoticeKind.viewerPending.blocksSomeone)
        XCTAssertTrue(SharerNoticeKind.controlRequested.blocksSomeone)
        XCTAssertFalse(SharerNoticeKind.viewerJoined.blocksSomeone)
        XCTAssertFalse(SharerNoticeKind.viewerLeft.blocksSomeone)
    }

    /// Urgency is narrower than actionability: a request-to-share arrives
    /// while idle and has a natural retry, so marking it urgent would also
    /// get Time Sensitive (revoked per app, not per notification) disarmed.
    func testRequestToShareIsActionableButNotUrgent() {
        XCTAssertFalse(SharerNoticeKind.requestToShare.actions.isEmpty)
        XCTAssertFalse(SharerNoticeKind.requestToShare.blocksSomeone)
    }

    /// Urgency implies actionability, not the reverse.
    func testEveryBlockingKindIsActionable() {
        for kind in SharerNoticeKind.allCases where kind.blocksSomeone {
            XCTAssertFalse(kind.actions.isEmpty, "\(kind) blocks a peer but offers no way to act")
        }
    }

    func testJoinAndLeaveAreSymmetric() {
        XCTAssertEqual(
            SharerNoticeKind.viewerJoined.actions, SharerNoticeKind.viewerLeft.actions)
        XCTAssertEqual(
            SharerNoticeKind.viewerJoined.blocksSomeone,
            SharerNoticeKind.viewerLeft.blocksSomeone)
    }

    /// Closing a banner is not a decision about a peer.
    func testDismissIsNeverAnOfferedButton() {
        for kind in SharerNoticeKind.allCases {
            XCTAssertFalse(kind.actions.contains(.dismiss), "\(kind) offers dismiss as a button")
        }
    }

    // MARK: - Action keys

    /// Pinned because these keys leave the process — the notification daemon
    /// stores and hands them back verbatim, so a rename breaks buttons
    /// already on screen.
    func testActionKeysAreStable() {
        XCTAssertEqual(NoticeAction.approve.rawValue, "approve")
        XCTAssertEqual(NoticeAction.deny.rawValue, "deny")
        XCTAssertEqual(NoticeAction.dismiss.rawValue, "dismiss")
    }

    /// A host passing its button label as the key gets a working English
    /// build and a localized build where every press silently drops.
    func testALabelIsNotAnActionKey() {
        XCTAssertNil(NoticeAction(rawValue: "Accept"))
        XCTAssertNil(NoticeAction(rawValue: "Deny"))
        XCTAssertNil(NoticeAction(rawValue: "Godkänn"))
        XCTAssertNil(NoticeAction(rawValue: ""))
        XCTAssertEqual(NoticeAction(rawValue: "approve"), .approve)
    }

    // MARK: - Round-tripping the identifier

    /// A press comes back as opaque strings only — no live state, no notice
    /// object, possibly an hour of delay. Every kind must survive that round trip.
    func testEveryKindRoundTripsThroughItsID() {
        for kind in SharerNoticeKind.allCases {
            let notice = SharerNotice(kind: kind, identity: "100.64.0.1:49152", label: "wisp")
            let decoded = SharerNotice.decodeID(notice.id)
            XCTAssertEqual(decoded?.kind, kind)
            XCTAssertEqual(decoded?.identity, "100.64.0.1:49152")
        }
    }

    /// The split is on the FIRST colon — a last-colon split works right up
    /// until IPv6, where it lands Accept on a peer key that never existed.
    func testIdentityMayContainColons() {
        let identities = [
            "100.64.0.1:51820",
            "fd7a:115c:a1e0::1234:5678",
            "[fd7a:115c:a1e0::1234:5678]:7447",
            "a:b:c:d"
        ]
        for identity in identities {
            let notice = SharerNotice(kind: .viewerPending, identity: identity, label: "wisp")
            XCTAssertEqual(SharerNotice.decodeID(notice.id)?.identity, identity)
        }
    }

    /// Anything not minted here decodes to nil rather than a guess (e.g. a
    /// banner from another build still in notification centre after an
    /// update). Acting on the wrong peer is worse than a dead button.
    func testUnmintedIdentifiersDecodeToNil() {
        XCTAssertNil(SharerNotice.decodeID("viewerPending"), "no separator")
        XCTAssertNil(SharerNotice.decodeID("viewerPending:"), "empty identity")
        XCTAssertNil(SharerNotice.decodeID("viewerRetired:100.64.0.1"), "unknown kind")
        XCTAssertNil(SharerNotice.decodeID(":100.64.0.1"), "empty kind")
        XCTAssertNil(SharerNotice.decodeID(""))
        XCTAssertNil(
            SharerNotice.decodeID("F1B0A5C2-3D4E-4A6B-8C9D-0E1F2A3B4C5D"),
            "the random-UUID identifier this consolidation replaced")
    }

    // MARK: - Sound

    /// The ding is played by the notification daemon — another process, so
    /// "exclude our own audio" doesn't drop it. It goes out with the share.
    func testNothingSoundsWhileCapturing() {
        XCTAssertFalse(SharerNoticeDecision.playsSound(isCapturing: true))
    }

    /// No capture to leak into, and it's the non-urgent kind — the sound is
    /// the only thing that makes it noticeable.
    func testAnIdleMachineStillDings() {
        XCTAssertTrue(SharerNoticeDecision.playsSound(isCapturing: false))
    }

    func testMidShareKindsAreAlwaysSilent() {
        for kind in SharerNoticeKind.allCases where kind.blocksSomeone {
            XCTAssertFalse(
                SharerNoticeDecision.playsSound(isCapturing: true),
                "\(kind) fires only during a share and must not be audible to viewers")
        }
    }

    // MARK: - Generation ordering

    func testOlderGenerationIsStale() {
        XCTAssertTrue(SharerNoticeDecision.isStale(generation: 4, lastApplied: 5))
    }

    func testNewerGenerationIsNotStale() {
        XCTAssertFalse(SharerNoticeDecision.isStale(generation: 6, lastApplied: 5))
    }

    /// Treating equality as stale would drop the first delivery of every
    /// generation.
    func testEqualGenerationIsNotStale() {
        XCTAssertFalse(SharerNoticeDecision.isStale(generation: 5, lastApplied: 5))
    }

    /// Prevents a reordered `nil` from clearing a grant that's still live
    /// (which on macOS also unregisters the panic hotkey).
    func testReorderedClearAfterNewerGrantIsDropped() {
        var lastApplied: UInt64 = 0
        for (generation, grantIsLive) in [(UInt64(1), true), (UInt64(3), true), (UInt64(2), false)] {
            guard !SharerNoticeDecision.isStale(generation: generation, lastApplied: lastApplied)
            else { continue }
            lastApplied = generation
            XCTAssertTrue(grantIsLive, "a stale clear was applied over a live grant")
        }
        XCTAssertEqual(lastApplied, 3)
    }

}
