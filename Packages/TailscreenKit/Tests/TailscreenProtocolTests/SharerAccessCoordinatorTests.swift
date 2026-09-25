import XCTest

@testable import TailscreenProtocol

/// The sharer's remember/forget layer.
///
/// Every case here fails silently in production: a decision that never
/// persists, one that persists against the wrong machine, a Forget that
/// un-forgets itself a second later.
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
        // Pushes drive the server's admission-gate re-run; a change that doesn't push is never applied.
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
        // The netmap lookup for a safe key is async; "not yet identified" must not mean "discarded".
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

        // Roster is re-emitted on any change, including the StableNodeID landing.
        let changed = coordinator.noteRoster([
            identity("100.64.0.5:1", "nABC", "robert-macbook")
        ])
        XCTAssertTrue(changed)
        XCTAssertEqual(coordinator.remembered(stableID: "nABC"), .deny)
        XCTAssertEqual(pushes().last, ["nABC": .deny])
        XCTAssertFalse(coordinator.isDeferred(rowID: "100.64.0.5:1"))
    }

    func testAQueuedDecisionForAPeerThatLeftIsDropped() {
        // Otherwise it lands on the next connection from the same address, which behind one NAT
        // can be a different machine.
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
        // Otherwise the queued intent silently re-applies once the identity resolves.
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
        // A decision is often made against an IP before the hostname resolves; without this
        // refresh the settings list would show the IP forever.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "100.64.0.5", policy: .deny)
        let changed = coordinator.noteRoster([identity("a:1", "nABC", "robert-macbook")])
        XCTAssertTrue(changed)
        XCTAssertEqual(coordinator.policies["nABC"], .deny)
    }

    func testAnUnchangedRosterDoesNotPush() {
        // The roster ticks on every health update; pushing unconditionally would re-run
        // admission several times a second for nothing.
        let (coordinator, pushes) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "robert-macbook", policy: .deny)
        let before = pushes().count
        XCTAssertFalse(coordinator.noteRoster([identity("a:1", "nABC", "robert-macbook")]))
        XCTAssertEqual(pushes().count, before)
    }

    func testResetForgetsQueuedDecisionsButNotStoredOnes() {
        // Stopping a share ends connections, not the sharer's memory of who they blocked.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "peer", policy: .deny)
        coordinator.remember(rowID: "b:1", stableID: nil, displayName: "peer2", policy: .allow)

        coordinator.reset()
        XCTAssertFalse(coordinator.isDeferred(rowID: "b:1"))
        XCTAssertEqual(coordinator.remembered(stableID: "nABC"), .deny)
    }

    func testPoliciesSurviveANewCoordinatorOverTheSameDirectory() {
        // A decision made last week must be there at the next share, a different process.
        let (coordinator, _) = makeCoordinator()
        coordinator.remember(
            rowID: "a:1", stableID: "nABC", displayName: "peer", policy: .deny)

        let reopened = SharerAccessCoordinator(store: PeerAccessStore(directory: directory))
        XCTAssertEqual(reopened.remembered(stableID: "nABC"), .deny)
    }
}
