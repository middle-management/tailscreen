import XCTest

@testable import TailscreenProtocol

/// `PeerAccessStore` — the remembered allow/deny file the Linux and Windows
/// apps share.
///
/// Worth pinning because this is the persistence half of the gap that lets
/// those two hosts admit a viewer and then never change their mind, and every
/// way it can go wrong is quiet: a decision that fails to save looks identical
/// to one nobody made, and a decision that reloads wrong is only visible the
/// next time that peer connects.
final class PeerAccessStoreTests: XCTestCase {

    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "peer-access-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func makeStore() -> PeerAccessStore { PeerAccessStore(directory: directory) }

    // MARK: - Round trip

    func testEmptyOnFirstRun() {
        XCTAssertTrue(makeStore().entries.isEmpty)
    }

    /// The whole point: a decision made in one session is still there in the
    /// next one.
    func testDecisionSurvivesAReload() {
        let first = makeStore()
        first.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)
        first.upsert(stableID: "nBBB", displayName: "ember", policy: .deny)

        let second = makeStore()
        XCTAssertEqual(second.policy(for: "nAAA"), .allow)
        XCTAssertEqual(second.policy(for: "nBBB"), .deny)
    }

    /// Oldest first, so a settings list does not reshuffle under the user when
    /// an unrelated peer's name is refreshed.
    func testInsertionOrderIsPreserved() {
        let store = makeStore()
        store.upsert(stableID: "n1", displayName: "one", policy: .allow)
        store.upsert(stableID: "n2", displayName: "two", policy: .allow)
        store.upsert(stableID: "n3", displayName: "three", policy: .deny)
        store.refreshDisplayName(stableID: "n1", displayName: "ONE")

        XCTAssertEqual(makeStore().entries.map(\.stableID), ["n1", "n2", "n3"])
    }

    func testUnknownPeerHasNoPolicy() {
        XCTAssertNil(makeStore().policy(for: "nZZZ"))
    }

    // MARK: - Upsert

    func testUpsertFlipsPolicyInPlace() {
        let store = makeStore()
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .deny)

        XCTAssertEqual(store.entries.count, 1, "a flip must not add a second row")
        XCTAssertEqual(makeStore().policy(for: "nAAA"), .deny)
    }

    /// `addedAt` records when you first decided about this peer. A later rename
    /// or a change of mind is not a new decision, and resetting it would
    /// reorder the settings list under the user.
    func testUpsertKeepsTheOriginalAddedAt() throws {
        let store = makeStore()
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)
        let original = try XCTUnwrap(store.entries.first?.addedAt)

        store.upsert(stableID: "nAAA", displayName: "renamed", policy: .deny)
        XCTAssertEqual(store.entries.first?.addedAt, original)
    }

    /// Hosts re-publish on a real change only; a no-op upsert must say so or
    /// every netmap tick redraws the list.
    func testUpsertReportsWhetherAnythingChanged() {
        let store = makeStore()
        XCTAssertTrue(store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow))
        XCTAssertFalse(
            store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow),
            "an identical upsert changed nothing and must report so")
        XCTAssertTrue(store.upsert(stableID: "nAAA", displayName: "wisp", policy: .deny))
    }

    // MARK: - Remove and rename

    func testRemoveForgetsThePeer() {
        let store = makeStore()
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .deny)
        XCTAssertTrue(store.remove(stableID: "nAAA"))

        XCTAssertNil(makeStore().policy(for: "nAAA"), "a forgotten peer must ask again")
    }

    func testRemoveOfUnknownPeerReportsNoChange() {
        XCTAssertFalse(makeStore().remove(stableID: "nZZZ"))
    }

    /// A rename is cosmetic. Losing the policy while updating the label would
    /// silently re-admit someone who was blocked.
    func testRefreshDisplayNameLeavesThePolicyAlone() {
        let store = makeStore()
        store.upsert(stableID: "nAAA", displayName: "old-name", policy: .deny)
        XCTAssertTrue(store.refreshDisplayName(stableID: "nAAA", displayName: "new-name"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.first?.displayName, "new-name")
        XCTAssertEqual(reloaded.policy(for: "nAAA"), .deny)
    }

    func testRefreshDisplayNameIsANoOpForUnknownOrUnchanged() {
        let store = makeStore()
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)
        XCTAssertFalse(store.refreshDisplayName(stableID: "nZZZ", displayName: "ghost"))
        XCTAssertFalse(store.refreshDisplayName(stableID: "nAAA", displayName: "wisp"))
    }

    // MARK: - The server snapshot

    /// The map the admission gate actually reads. Built by the shared
    /// projection so the two stores cannot disagree about what a remembered
    /// decision means.
    func testPoliciesSnapshotMatchesEntries() {
        let store = makeStore()
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)
        store.upsert(stableID: "nBBB", displayName: "ember", policy: .deny)

        XCTAssertEqual(store.policiesByStableID, ["nAAA": .allow, "nBBB": .deny])
    }

    func testPoliciesSnapshotIsEmptyWhenNothingIsRemembered() {
        XCTAssertTrue(makeStore().policiesByStableID.isEmpty)
    }

    // MARK: - Degradation

    /// Refusing to start because a JSON file is malformed would be worse than
    /// forgetting: a lost *allow* costs one approval prompt, and a lost *deny*
    /// is caught by the gate, which defaults to asking.
    func testCorruptFileDegradesToNothingRemembered() throws {
        let path = directory + "/viewer-access.json"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))

        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)

        // And it recovers: the next decision overwrites the bad file.
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)
        XCTAssertEqual(makeStore().policy(for: "nAAA"), .allow)
    }

    /// The store creates its own directory, so a first run on a machine with
    /// no config dir yet does not silently drop every decision.
    func testMissingDirectoryIsCreated() {
        let nested = directory + "/deeper/still"
        let store = PeerAccessStore(directory: nested)
        store.upsert(stableID: "nAAA", displayName: "wisp", policy: .allow)

        XCTAssertEqual(PeerAccessStore(directory: nested).policy(for: "nAAA"), .allow)
    }

    /// Two installs pointed at different directories must not see each other's
    /// decisions — the same isolation `TAILSCREEN_INSTANCE` gives node state.
    func testSeparateDirectoriesAreIndependent() {
        let other = directory + "-other"
        defer { try? FileManager.default.removeItem(atPath: other) }

        makeStore().upsert(stableID: "nAAA", displayName: "wisp", policy: .deny)
        XCTAssertNil(PeerAccessStore(directory: other).policy(for: "nAAA"))
    }
}
