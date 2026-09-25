import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// `SharerSessionCore` — the share-generation stamp, the grant high-water
/// mark and the invite queue that both share engines hold, each behind its
/// own guard. Pinned here rather than per-engine because the two engines are
/// deliberately different shapes (`LinuxShareSession` is `@MainActor`,
/// `WindowsShareSession` is lock-guarded); a value type lets one set of
/// rules serve both without unifying the isolation models.
final class SharerSessionCoreTests: XCTestCase {

    // MARK: The share stamp

    func testEachAttemptGetsAFreshGenerationAndOnlyTheLatestIsCurrent() {
        var core = SharerSessionCore()
        let first = core.beginShare()
        XCTAssertTrue(core.isCurrentShare(first))

        let second = core.beginShare()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(core.isCurrentShare(second))
        XCTAssertFalse(
            core.isCurrentShare(first),
            "a callback stamped by the previous attempt must drop itself")
    }

    /// `start()` spans tsnet bring-up, so a stop lands inside it routinely —
    /// the tail that wakes afterwards must know its share is over, or it
    /// publishes "Sharing" over an idle session.
    func testEndingAShareInvalidatesEveryStampFromIt() {
        var core = SharerSessionCore()
        let generation = core.beginShare()
        core.endShare()
        XCTAssertFalse(core.isCurrentShare(generation))
        XCTAssertFalse(core.isCurrentShare(0))
    }

    // MARK: The grant high-water mark

    /// A host hopping `onControlGrantChanged` to its UI thread can deliver
    /// an older snapshot last, and applying its `nil` would falsely say
    /// nobody is controlling the machine.
    func testAReorderedSnapshotWithinAShareIsDiscarded() {
        var core = SharerSessionCore()
        let share = core.beginShare()

        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 5))
        XCTAssertFalse(
            core.shouldApplyGrant(share: share, generation: 4),
            "an older snapshot delivered last must not clear a live grant")
    }

    /// Equal generations are NOT stale — re-applying is idempotent.
    func testTheSameGenerationTwiceIsAppliedTwice() {
        var core = SharerSessionCore()
        let share = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 5))
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 5))
    }

    /// Both guards, not either: ending a share resets the high-water mark
    /// to zero, so a snapshot in flight from the OLD server (generation 7)
    /// isn't stale against 0 — without the share stamp it would land, and
    /// also leave the mark at 7, swallowing the next share's snapshots.
    func testALateSnapshotFromAnEndedShareIsDroppedAndDoesNotPoisonTheNextOne() {
        var core = SharerSessionCore()
        let first = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: first, generation: 7))

        core.endShare()
        XCTAssertFalse(
            core.shouldApplyGrant(share: first, generation: 7),
            "the share stamp is what rejects it — the mark alone cannot")

        let second = core.beginShare()
        XCTAssertTrue(
            core.shouldApplyGrant(share: second, generation: 1),
            "the next share's first snapshot counts from zero and must still land")
    }

    func testClearingTheGrantHistoryLetsALowGenerationLandAgain() {
        var core = SharerSessionCore()
        let share = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 9))
        XCTAssertFalse(core.shouldApplyGrant(share: share, generation: 2))

        core.clearGrantHistory()
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 2))
        XCTAssertTrue(core.isCurrentShare(share), "clearing the mark is not ending the share")
    }

    func testBeginningAShareRestartsTheMark() {
        var core = SharerSessionCore()
        let first = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: first, generation: 40))

        let second = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: second, generation: 1))
    }

    // MARK: Invitations

    /// Accepting happens before the share exists, so the IP must be held
    /// and replayed, or the invitee arrives at their own approval gate.
    func testAnInviteWithNoServerIsHeldAndDrainedExactlyOnce() {
        var core = SharerSessionCore()
        core.noteInvite("100.64.0.7", hasServer: false)
        core.noteInvite("100.64.0.9", hasServer: false)
        XCTAssertEqual(core.heldInvites, ["100.64.0.7", "100.64.0.9"])

        XCTAssertEqual(core.drainInvites(), ["100.64.0.7", "100.64.0.9"])
        XCTAssertTrue(core.heldInvites.isEmpty)
        XCTAssertTrue(core.drainInvites().isEmpty, "a second start must not re-invite anyone")
    }

    /// An invite made while a share is running is delivered and finished —
    /// holding it too would replay it into the next share, a free pass for
    /// somebody nobody invited to that one.
    func testAnInviteToALiveShareIsNotRememberedForTheNextOne() {
        var core = SharerSessionCore()
        core.noteInvite("100.64.0.7", hasServer: true)
        XCTAssertTrue(
            core.heldInvites.isEmpty,
            "the live server was told directly; there is nothing left to replay")
    }

    func testEndingAShareKeepsHeldInvitesForTheNextOne() {
        var core = SharerSessionCore()
        core.beginShare()
        core.noteInvite("100.64.0.7", hasServer: false)
        core.endShare()
        XCTAssertEqual(core.heldInvites, ["100.64.0.7"])

        core.beginShare()
        XCTAssertEqual(core.drainInvites(), ["100.64.0.7"])
    }

    func testRepeatedInvitesForOneAddressCollapse() {
        var core = SharerSessionCore()
        core.noteInvite("100.64.0.7", hasServer: false)
        core.noteInvite("100.64.0.7", hasServer: false)
        XCTAssertEqual(core.heldInvites.count, 1)
    }
}
