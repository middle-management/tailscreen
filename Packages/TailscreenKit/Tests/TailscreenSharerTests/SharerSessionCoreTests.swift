import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// `SharerSessionCore` — the share-generation stamp, the grant high-water mark
/// and the invite queue that both share engines hold, each behind its own
/// guard.
///
/// The point of pinning it here rather than in either engine's suite is that
/// the two engines are deliberately different shapes: `LinuxShareSession` is
/// `@MainActor`, `WindowsShareSession` is lock-guarded, and
/// `.claude/rules/linux.md` explains why that difference is load-bearing. A
/// value type is what lets one set of rules serve both without unifying the
/// isolation models — and it is what finally gives the Windows engine's copy of
/// these rules a test at all.
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

    /// The stamp's whole job: `start()` spans tsnet bring-up — minutes, on an
    /// interactive browser login — so a stop lands inside it routinely. The tail
    /// that wakes afterwards has to know the share it belongs to is over, or it
    /// publishes "Sharing" over an idle session: a share the person cannot see,
    /// cannot stop, and did not ask for.
    func testEndingAShareInvalidatesEveryStampFromIt() {
        var core = SharerSessionCore()
        let generation = core.beginShare()
        core.endShare()
        XCTAssertFalse(core.isCurrentShare(generation))
        // And nothing else accidentally becomes current in its place.
        XCTAssertFalse(core.isCurrentShare(0))
    }

    // MARK: The grant high-water mark

    /// Within one share the reorder guard is the point: a host that hops
    /// `onControlGrantChanged` to its UI thread can deliver an older snapshot
    /// last, and applying its `nil` would tell the sharer nobody is controlling
    /// their machine while somebody is.
    func testAReorderedSnapshotWithinAShareIsDiscarded() {
        var core = SharerSessionCore()
        let share = core.beginShare()

        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 5))
        XCTAssertFalse(
            core.shouldApplyGrant(share: share, generation: 4),
            "an older snapshot delivered last must not clear a live grant")
    }

    /// Equal generations are NOT stale: two racing notifies can observe the
    /// same pair, and re-applying it is idempotent.
    func testTheSameGenerationTwiceIsAppliedTwice() {
        var core = SharerSessionCore()
        let share = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 5))
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 5))
    }

    /// **Both guards, not either — the hole PR #244 closed.**
    ///
    /// `isStale` only rejects a generation below the high-water mark, and
    /// ending a share resets that mark to zero (it has to: a fresh server counts
    /// from zero). So a snapshot still in flight from the OLD server — say
    /// generation 7 — is not stale against 0. Without the share stamp it lands,
    /// telling the sharer somebody is driving a machine they just stopped
    /// sharing, and it leaves the mark at 7, which then swallows the NEXT
    /// share's first snapshots: a grant that silently never appears, from a stop
    /// that looked clean.
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

    /// A teardown that clears the control rows without ending the share must
    /// still forget the mark, or the next server's generation-1 snapshot is
    /// discarded as stale against this one's.
    func testClearingTheGrantHistoryLetsALowGenerationLandAgain() {
        var core = SharerSessionCore()
        let share = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 9))
        XCTAssertFalse(core.shouldApplyGrant(share: share, generation: 2))

        core.clearGrantHistory()
        XCTAssertTrue(core.shouldApplyGrant(share: share, generation: 2))
        XCTAssertTrue(core.isCurrentShare(share), "clearing the mark is not ending the share")
    }

    /// Opening a share restarts the mark too, for the same reason: a fresh
    /// server starts its own sequence at zero and a mark carried over from the
    /// last share would discard this one's first snapshots.
    func testBeginningAShareRestartsTheMark() {
        var core = SharerSessionCore()
        let first = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: first, generation: 40))

        let second = core.beginShare()
        XCTAssertTrue(core.shouldApplyGrant(share: second, generation: 1))
    }

    // MARK: Invitations

    /// Accepting somebody's ask necessarily happens before the share exists —
    /// that is what accepting means — so the IP has to be held and replayed, or
    /// the person this machine just invited arrives at its own approval gate and
    /// is asked to wait.
    func testAnInviteWithNoServerIsHeldAndDrainedExactlyOnce() {
        var core = SharerSessionCore()
        core.noteInvite("100.64.0.7", hasServer: false)
        core.noteInvite("100.64.0.9", hasServer: false)
        XCTAssertEqual(core.heldInvites, ["100.64.0.7", "100.64.0.9"])

        XCTAssertEqual(core.drainInvites(), ["100.64.0.7", "100.64.0.9"])
        XCTAssertTrue(core.heldInvites.isEmpty)
        XCTAssertTrue(core.drainInvites().isEmpty, "a second start must not re-invite anyone")
    }

    /// **The leak this rule closes.** An invite made while a share is already
    /// running is delivered to that server and is finished. Holding it as well
    /// — which the GTK engine did — replays it into the NEXT share: a free pass
    /// through the approval gate for somebody nobody invited to that one.
    func testAnInviteToALiveShareIsNotRememberedForTheNextOne() {
        var core = SharerSessionCore()
        core.noteInvite("100.64.0.7", hasServer: true)
        XCTAssertTrue(
            core.heldInvites.isEmpty,
            "the live server was told directly; there is nothing left to replay")
    }

    /// An ask accepted while the last share was winding down is an invitation to
    /// the share about to start, so ending a share must not drop it.
    func testEndingAShareKeepsHeldInvitesForTheNextOne() {
        var core = SharerSessionCore()
        core.beginShare()
        core.noteInvite("100.64.0.7", hasServer: false)
        core.endShare()
        XCTAssertEqual(core.heldInvites, ["100.64.0.7"])

        core.beginShare()
        XCTAssertEqual(core.drainInvites(), ["100.64.0.7"])
    }

    /// A retry of the same ask is the same person, not a second one.
    func testRepeatedInvitesForOneAddressCollapse() {
        var core = SharerSessionCore()
        core.noteInvite("100.64.0.7", hasServer: false)
        core.noteInvite("100.64.0.7", hasServer: false)
        XCTAssertEqual(core.heldInvites.count, 1)
    }
}
