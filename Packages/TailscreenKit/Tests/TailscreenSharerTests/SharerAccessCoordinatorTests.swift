import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// The sharer's remember/forget layer.
///
/// Every case here fails silently in production: a decision that never
/// persists, one that persists against the wrong machine, a Forget that
/// un-forgets itself a second later. On Linux and Windows there was no code
/// here at all before this, and on macOS it was five behaviours spread through
/// a view model with no test between them and the user.
final class SharerAccessCoordinatorTests: XCTestCase {
    private var directory = ""

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "tailscreen-access-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func makeCoordinator() -> (SharerAccessCoordinator, () -> [[String: PeerPolicy]]) {
        let coordinator = SharerAccessCoordinator(store: PeerAccessStore(directory: directory))
        // The pushes are the observable side effect that matters: the server
        // re-runs its admission gate and sweeps the connected roster off this
        // map, so a change that does not push is a decision the live share
        // never hears about.
        final class Box {
            var pushes: [[String: PeerPolicy]] = []
        }
        let box = Box()
        coordinator.onPoliciesChanged = { box.pushes.append($0) }
        return (coordinator, { box.pushes })
    }

    private func identity(
        _ id: String, _ stableID: String?, _ name: String = "peer"
    )
        -> ViewerRosterDecision.RosterIdentity
    {
        ViewerRosterDecision.RosterIdentity(id: id, stableID: stableID, displayName: name)
    }

    // MARK: Remember

    func testRememberingAResolvedPeerPersistsAndPushesImmediately() {
        let (coordinator, pushes) = makeCoordinator()
        let applied = coordinator.remember(
            rowID: "100.64.0.5:1", stableID: "nABC", displayName: "robert-macbook",
            policy: .deny)
        XCTAssertTrue(applied)
        XCTAssertEqual(coordinator.remembered(stableID: "nABC"), .deny)
        XCTAssertEqual(pushes(), [["nABC": .deny]])
    }

    func testRememberingAnUnresolvedPeerQueuesRatherThanDropping() {
        // The case the whole queue exists for: a sharer who wants somebody gone
        // wants it NOW, and the netmap lookup producing the only key safe to
        // remember them under is asynchronous. "Not yet identified" must not
        // mean "your decision was discarded".
        let (coordinator, pushes) = makeCoordinator()
        let applied = coordinator.remember(
            rowID: "100.64.0.5:1", stableID: nil, displayName: "100.64.0.5", policy: .deny)
        XCTAssertFalse(applied, "not persisted yet — the caller words the row accordingly")
        XCTAssertTrue(coordinator.isDeferred(rowID: "100.64.0.5:1"))
        XCTAssertTrue(pushes().isEmpty, "nothing to push until there is a key")
    }

    func testAQueuedDecisionLandsWhenTheIdentityResolves() {
        let (coordinator, pushes) = makeCoordinator()
        coordinator.remember(
            rowID: "100.64.0.5:1", stableID: nil, displayName: "100.64.0.5", policy: .deny)

        // The roster is re-emitted whenever anything about it changes —
        // including the StableNodeID landing, which is the event being waited
        // on.
        let changed = coordinator.noteRoster([
            identity("100.64.0.5:1", "nABC", "robert-macbook")
        ])
        XCTAssertTrue(changed)
        XCTAssertEqual(coordinator.remembered(stableID: "nABC"), .deny)
        XCTAssertEqual(pushes().last, ["nABC": .deny])
        XCTAssertFalse(coordinator.isDeferred(rowID: "100.64.0.5:1"))
    }

    func testAQueuedDecisionForAPeerThatLeftIsDropped() {
        // Otherwise it lands on THE NEXT CONNECTION FROM THE SAME ADDRESS,
        // which behind one NAT can be an entirely different machine.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "100.64.0.5:1", stableID: nil, displayName: "100.64.0.5", policy: .deny)
        coordinator.noteRoster([])  // they disconnected before resolving

        coordinator.noteRoster([identity("100.64.0.5:1", "nSOMEONE-ELSE")])
        XCTAssertNil(
            coordinator.remembered(stableID: "nSOMEONE-ELSE"),
            "a stale intent must not be applied to whoever arrives next")
    }

    // MARK: Forget

    func testForgetRemovesThePolicyAndPushes() {
        let (coordinator, pushes) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "peer", policy: .allow)
        XCTAssertTrue(coordinator.forget(rowID: "a:1", stableID: "nABC"))
        XCTAssertNil(coordinator.remembered(stableID: "nABC"))
        XCTAssertEqual(pushes().last, [:])
    }

    func testForgetAlsoCancelsAQueuedDecision() {
        // Forgetting the stored policy while leaving an intent queued would
        // silently re-apply the decision the moment the identity resolved —
        // the exact opposite of what Forget means, and invisible until it
        // happened.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(rowID: "a:1", stableID: nil, displayName: "peer", policy: .deny)
        _ = coordinator.forget(rowID: "a:1", stableID: nil)
        XCTAssertFalse(coordinator.isDeferred(rowID: "a:1"))

        coordinator.noteRoster([identity("a:1", "nABC")])
        XCTAssertNil(coordinator.remembered(stableID: "nABC"))
    }

    func testForgettingSomethingUnremembteredIsANoOp() {
        let (coordinator, pushes) = makeCoordinator()
        XCTAssertFalse(coordinator.forget(rowID: "a:1", stableID: "nNOPE"))
        XCTAssertTrue(pushes().isEmpty, "a no-op must not push and re-run the admission gate")
    }

    // MARK: Roster upkeep

    func testDisplayNamesAreRefreshedFromTheRoster() {
        // A decision is often made against an IP, seconds before the hostname
        // resolves. Without this the settings list would show that IP forever,
        // which is unusable for deciding whether to un-block someone.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "100.64.0.5", policy: .deny)
        let changed = coordinator.noteRoster([identity("a:1", "nABC", "robert-macbook")])
        XCTAssertTrue(changed)
        XCTAssertEqual(coordinator.policies["nABC"], .deny)
    }

    func testAnUnchangedRosterDoesNotPush() {
        // Pushed on every roster tick, and the roster ticks on every health
        // update — so a push per tick would re-run the admission gate several
        // times a second for nothing.
        let (coordinator, pushes) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "robert-macbook", policy: .deny)
        let before = pushes().count
        XCTAssertFalse(coordinator.noteRoster([identity("a:1", "nABC", "robert-macbook")]))
        XCTAssertEqual(pushes().count, before)
    }

    func testResetForgetsQueuedDecisionsButNotStoredOnes() {
        // Stopping a share ends the connections, not the sharer's memory of who
        // they blocked.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "peer", policy: .deny)
        coordinator.remember(rowID: "b:1", stableID: nil, displayName: "peer2", policy: .allow)

        coordinator.reset()
        XCTAssertFalse(coordinator.isDeferred(rowID: "b:1"))
        XCTAssertEqual(coordinator.remembered(stableID: "nABC"), .deny)
    }

    func testPoliciesSurviveANewCoordinatorOverTheSameDirectory() {
        // The point of persisting at all: a decision made last week has to be
        // there at the next share, which is a different process.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "peer", policy: .deny)

        let reopened = SharerAccessCoordinator(store: PeerAccessStore(directory: directory))
        XCTAssertEqual(reopened.remembered(stableID: "nABC"), .deny)
    }
}
