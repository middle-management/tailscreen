import XCTest

@testable import TailscreenProtocol

/// `SharerNoticeDecision` — when to interrupt the sharer, and about whom.
///
/// Worth pinning because both failure directions are invisible in normal use.
/// Under-notifying strands a viewer at an approval gate the sharer never sees;
/// over-notifying trains the sharer to swipe the banner away, which strands the
/// next viewer just as thoroughly. Neither produces an error or a log line, and
/// neither is reproducible without a second machine — so the rules are pinned
/// here instead.
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

    /// The core anti-spam rule. Every host delivers whole-list snapshots, and
    /// those snapshots are re-emitted for reasons that have nothing to do with
    /// the peer in question — a hostname finally resolving off the netmap, or
    /// another row changing. Re-announcing on each would make the notification
    /// useless within one share.
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

    /// A label change on an already-notified identity is exactly the
    /// hostname-resolution case: same peer, better name, no second banner.
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

    /// The other half of the rule: a peer that gives up and genuinely asks
    /// again must be announced again. Without the prune, one denied request
    /// would silence that peer for the rest of the share.
    func testLeavingAndReturningPostsAgain() {
        let first = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: [])

        // Request withdrawn / denied — the row leaves the snapshot.
        let empty = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested, candidates: [], alreadyNotified: first.notified)
        XCTAssertTrue(empty.post.isEmpty)
        XCTAssertTrue(empty.notified.isEmpty, "a departed identity must be forgotten")

        // Same peer asks again.
        let again = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested,
            candidates: candidates(("100.64.0.1", "wisp")),
            alreadyNotified: empty.notified)
        XCTAssertEqual(again.post.count, 1)
    }

    /// One row leaving must not amnesty the rows that stayed.
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

    /// Kinds share one notified-set on the host side, so their ids must not
    /// collide: a peer's pending notice must not suppress its later control
    /// request.
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

    /// A notice that offers a choice with no consequence trains people to
    /// ignore the ones that have one.
    func testOnlyTheAsksAreActionable() {
        XCTAssertEqual(SharerNoticeKind.viewerPending.actions, [.approve, .deny])
        XCTAssertEqual(SharerNoticeKind.controlRequested.actions, [.approve, .deny])
        XCTAssertEqual(SharerNoticeKind.requestToShare.actions, [.approve, .deny])
        XCTAssertTrue(SharerNoticeKind.viewerJoined.actions.isEmpty)
        XCTAssertTrue(SharerNoticeKind.viewerLeft.actions.isEmpty)
    }

    /// Drives each platform's break-through-Focus level. Only the notices that
    /// strand somebody in a *running* session qualify.
    func testOnlyMidSessionAsksBlockSomeone() {
        XCTAssertTrue(SharerNoticeKind.viewerPending.blocksSomeone)
        XCTAssertTrue(SharerNoticeKind.controlRequested.blocksSomeone)
        XCTAssertFalse(SharerNoticeKind.viewerJoined.blocksSomeone)
        XCTAssertFalse(SharerNoticeKind.viewerLeft.blocksSomeone)
    }

    /// The case that makes urgency a *narrower* thing than actionability.
    ///
    /// A request-to-share is an ask with buttons, but it arrives while this
    /// machine is idle: nobody is mid-flow, and an invitation has a natural
    /// retry. Marking it urgent would also disarm the ones that are — Time
    /// Sensitive is revoked per app, not per notification, so one over-eager
    /// kind takes the whole set down with it.
    func testRequestToShareIsActionableButNotUrgent() {
        XCTAssertFalse(SharerNoticeKind.requestToShare.actions.isEmpty)
        XCTAssertFalse(SharerNoticeKind.requestToShare.blocksSomeone)
    }

    /// Urgency implies actionability, not the reverse: a kind that strands
    /// somebody without offering a way to unstrand them is a bug in the table.
    func testEveryBlockingKindIsActionable() {
        for kind in SharerNoticeKind.allCases where kind.blocksSomeone {
            XCTAssertFalse(kind.actions.isEmpty, "\(kind) blocks a peer but offers no way to act")
        }
    }

    /// Joined/left are a matched pair — one without the other reads as a bug
    /// to a sharer who saw the first and waited for the second.
    func testJoinAndLeaveAreSymmetric() {
        XCTAssertEqual(
            SharerNoticeKind.viewerJoined.actions, SharerNoticeKind.viewerLeft.actions)
        XCTAssertEqual(
            SharerNoticeKind.viewerJoined.blocksSomeone,
            SharerNoticeKind.viewerLeft.blocksSomeone)
    }

    /// Dismiss must never be synthesizable from the button list — closing a
    /// banner is not a decision about a peer, and a host that treated it as
    /// one would deny people by inattention.
    func testDismissIsNeverAnOfferedButton() {
        for kind in SharerNoticeKind.allCases {
            XCTAssertFalse(kind.actions.contains(.dismiss), "\(kind) offers dismiss as a button")
        }
    }

    // MARK: - Generation ordering

    func testOlderGenerationIsStale() {
        XCTAssertTrue(SharerNoticeDecision.isStale(generation: 4, lastApplied: 5))
    }

    func testNewerGenerationIsNotStale() {
        XCTAssertFalse(SharerNoticeDecision.isStale(generation: 6, lastApplied: 5))
    }

    /// Two racing notifies can legitimately observe the same pair, and
    /// re-applying it is idempotent. Treating equality as stale would drop the
    /// first delivery of every generation.
    func testEqualGenerationIsNotStale() {
        XCTAssertFalse(SharerNoticeDecision.isStale(generation: 5, lastApplied: 5))
    }

    /// The failure this exists to prevent: a reordered `nil` clearing a grant
    /// that is still live, which on macOS also unregisters the panic hotkey.
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

    // MARK: - id round trip

    /// The inverse a host with only one opaque string to work with depends on.
    /// Windows hands a button press back as the activation argument and
    /// nothing else, so `id` is both halves and this is how they come apart.
    func testIDRoundTripsForEveryKind() {
        for kind in SharerNoticeKind.allCases {
            let notice = SharerNotice(kind: kind, identity: "100.64.0.1:51820", label: "wisp")
            let decoded = SharerNotice.decodeID(notice.id)
            XCTAssertEqual(decoded?.kind, kind)
            XCTAssertEqual(decoded?.identity, "100.64.0.1:51820")
        }
    }

    /// The split is on the FIRST colon, and this is the case that proves it:
    /// an identity that itself contains colons must come back whole. Splitting
    /// on the last one reroutes the answer, and the two things it reroutes
    /// between are "let this person watch" and "let this person control my
    /// machine".
    func testIdentityKeepsItsOwnColons() {
        for identity in ["100.64.0.1:51820", "fd7a:115c:a1e0::1:9", "a:b:c:d"] {
            let notice = SharerNotice(kind: .viewerPending, identity: identity, label: "x")
            XCTAssertEqual(SharerNotice.decodeID(notice.id)?.identity, identity)
        }
    }

    /// Activation arguments arrive from whatever posted them, so a string that
    /// is not one of ours must not decode into an answer about a peer.
    func testForeignIDsDecodeToNil() {
        XCTAssertNil(SharerNotice.decodeID(""))
        XCTAssertNil(SharerNotice.decodeID("viewerPending"))
        XCTAssertNil(SharerNotice.decodeID("viewerPending:"))
        XCTAssertNil(SharerNotice.decodeID(":100.64.0.1"))
        XCTAssertNil(SharerNotice.decodeID("somethingElse:100.64.0.1"))
    }
}
