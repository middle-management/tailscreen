import XCTest

@testable import TailscreenProtocol

/// The sharer's roster decisions — the layer between "who is watching" and the
/// persistent allow/deny store.
///
/// Every case here is about a decision that is silent when wrong: a queued
/// intent that never applies, one that applies to the wrong machine, a block
/// that leaves the blocked person watching. None of them errors, and on two of
/// the three platforms there is no test suite closer to the UI than this one.
final class ViewerRosterActionsTests: XCTestCase {
    func testConnectedRowCanAlwaysBeKicked() {
        // Keyed by "ip:port", which is known the instant the connection exists
        // — so a sharer reaching for the ✕ in the first second of an unwanted
        // connection always finds it.
        XCTAssertTrue(ViewerRosterDecision.connectedActions(stableID: nil).canKick)
        XCTAssertTrue(ViewerRosterDecision.connectedActions(stableID: "nXYZ").canKick)
    }

    func testPendingRowHasNothingToKick() {
        XCTAssertFalse(ViewerRosterDecision.pendingActions(stableID: "nXYZ").canKick)
        XCTAssertTrue(ViewerRosterDecision.pendingActions(stableID: "nXYZ").canDecide)
    }

    func testRememberIsOfferedBeforeIdentityResolvesButMarkedDeferred() {
        // Offered rather than hidden: an affordance that blinks into existence
        // a moment after someone connects reads as a glitch, and is missing at
        // exactly the moment a sharer reaches for it.
        let unresolved = ViewerRosterDecision.connectedActions(stableID: nil)
        XCTAssertTrue(unresolved.canRemember)
        XCTAssertTrue(unresolved.rememberIsDeferred)

        let resolved = ViewerRosterDecision.connectedActions(stableID: "nXYZ")
        XCTAssertTrue(resolved.canRemember)
        XCTAssertFalse(resolved.rememberIsDeferred)
    }
}

final class ViewerPendingIntentsTests: XCTestCase {
    private func identity(
        _ id: String, _ stableID: String?, _ name: String = "peer"
    )
        -> ViewerRosterDecision.RosterIdentity
    {
        ViewerRosterDecision.RosterIdentity(id: id, stableID: stableID, displayName: name)
    }

    func testAnIntentAppliesWhenTheIdentityResolves() {
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "100.64.0.5:1234", policy: .allow)

        // Nothing to apply while the netmap lookup is still outstanding.
        XCTAssertTrue(intents.drain(snapshot: [identity("100.64.0.5:1234", nil)]).isEmpty)
        XCTAssertEqual(intents.count, 1)

        let applied = intents.drain(
            snapshot: [identity("100.64.0.5:1234", "nABC", "robert-macbook")])
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.stableID, "nABC")
        XCTAssertEqual(applied.first?.displayName, "robert-macbook")
        XCTAssertEqual(applied.first?.policy, .allow)
        XCTAssertTrue(intents.isEmpty, "an applied intent must not apply twice")
    }

    func testLastDecisionWins() {
        // A sharer who clicks Deny & Block after Always Allow means the second
        // one. Queueing both and replaying in arrival order would end on the
        // first — which is the one they changed their mind about.
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "a", policy: .allow)
        intents.queue(id: "a", policy: .deny)
        let applied = intents.drain(snapshot: [identity("a", "nA")])
        XCTAssertEqual(applied.map(\.policy), [.deny])
    }

    func testDrainIgnoresRowsWithNoQueuedIntent() {
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "a", policy: .allow)
        let applied = intents.drain(snapshot: [identity("b", "nB"), identity("c", "nC")])
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(intents.count, 1, "someone else's row must not consume this intent")
    }

    func testCancelRemovesAQueuedIntent() {
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "a", policy: .deny)
        intents.cancel(id: "a")
        XCTAssertTrue(intents.drain(snapshot: [identity("a", "nA")]).isEmpty)
    }

    func testQueuedExposesThePendingChoice() {
        // So a host can show the row as already decided rather than leaving the
        // button looking unpressed for as long as resolution takes.
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "a", policy: .deny)
        XCTAssertEqual(intents.queued(id: "a"), .deny)
        XCTAssertNil(intents.queued(id: "b"))
    }

    func testPruneForgetsRowsThatLeft() {
        // The case that makes this more than tidiness: a peer that gets a
        // Deny & Block and disconnects before its identity resolves would
        // otherwise have that intent applied to THE NEXT CONNECTION FROM THE
        // SAME ADDRESS — possibly a different machine behind one NAT, or the
        // same one the sharer has since decided to allow.
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "100.64.0.5:1234", policy: .deny)
        intents.prune(presentIDs: [])
        XCTAssertTrue(intents.isEmpty)
        XCTAssertTrue(intents.drain(snapshot: [identity("100.64.0.5:1234", "nA")]).isEmpty)
    }

    func testPruneKeepsRowsStillPresent() {
        var intents = ViewerRosterDecision.PendingIntents()
        intents.queue(id: "a", policy: .allow)
        intents.queue(id: "b", policy: .deny)
        intents.prune(presentIDs: ["a"])
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.queued(id: "a"), .allow)
    }

    func testDrainOnAnEmptyQueueIsFree() {
        var intents = ViewerRosterDecision.PendingIntents()
        XCTAssertTrue(intents.drain(snapshot: [identity("a", "nA")]).isEmpty)
    }
}

final class ViewerPolicyExpulsionTests: XCTestCase {
    private func identity(
        _ id: String, _ stableID: String?
    )
        -> ViewerRosterDecision.RosterIdentity
    {
        ViewerRosterDecision.RosterIdentity(id: id, stableID: stableID, displayName: id)
    }

    func testDenyExpelsSomeoneAlreadyWatching() {
        // A block that leaves the blocked person watching is not a block.
        let expelled = ViewerRosterDecision.expelledByPolicy(
            policies: ["nA": .deny],
            connected: [identity("a:1", "nA"), identity("b:1", "nB")])
        XCTAssertEqual(expelled, ["a:1"])
    }

    func testAllowExpelsNobody() {
        let expelled = ViewerRosterDecision.expelledByPolicy(
            policies: ["nA": .allow], connected: [identity("a:1", "nA")])
        XCTAssertTrue(expelled.isEmpty)
    }

    func testUnresolvedIdentityIsNotExpelled() {
        // Nothing to match against. Expelling on a guess would drop whoever
        // happened to be connecting at the moment a block was recorded for
        // someone else entirely.
        let expelled = ViewerRosterDecision.expelledByPolicy(
            policies: ["nA": .deny], connected: [identity("a:1", nil)])
        XCTAssertTrue(expelled.isEmpty)
    }
}
