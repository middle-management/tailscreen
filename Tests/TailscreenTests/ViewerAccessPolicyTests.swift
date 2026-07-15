import XCTest

@testable import Tailscreen

/// Unit tests for the viewer-consent machinery that runs without tsnet:
/// the persistent per-peer allow/deny store (`ViewerAccessPolicyStore`),
/// the pure admission gate extracted from the server
/// (`admissionDecision` / `drainDecision` — same pattern as
/// `ViewerLifecycleDecisionTests`), and the tri-state default migration in
/// `ViewerApprovalDefaults.load`.
final class ViewerAccessPolicyTests: XCTestCase {

    /// Scratch `UserDefaults` suite, wiped on teardown so runs don't
    /// contaminate each other (or the developer's real defaults).
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "viewer-access-policy-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - Store round-trip

    @MainActor
    func testStoreRoundTripsThroughDefaults() throws {
        let defaults = try makeScratchDefaults()
        let store = ViewerAccessPolicyStore(defaults: defaults)
        store.upsert(stableID: "nAAA", displayName: "alice-mbp", policy: .allow)
        store.upsert(stableID: "nBBB", displayName: "bob-mini", policy: .deny)

        // Compare the identity-bearing fields, not whole entries: `addedAt`
        // goes through JSON's decimal Double representation and may lose a
        // sub-microsecond of precision on the round-trip.
        let reloaded = ViewerAccessPolicyStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.map(\.stableID), store.entries.map(\.stableID))
        XCTAssertEqual(reloaded.entries.map(\.displayName), ["alice-mbp", "bob-mini"])
        XCTAssertEqual(reloaded.policy(for: "nAAA"), .allow)
        XCTAssertEqual(reloaded.policy(for: "nBBB"), .deny)
        XCTAssertNil(reloaded.policy(for: "nZZZ"))
    }

    @MainActor
    func testUpsertUpdatesPolicyAndNameButKeepsAddedAt() throws {
        let defaults = try makeScratchDefaults()
        let store = ViewerAccessPolicyStore(defaults: defaults)
        store.upsert(stableID: "nAAA", displayName: "old-name", policy: .allow)
        let originalAddedAt = try XCTUnwrap(store.entries.first).addedAt

        store.upsert(stableID: "nAAA", displayName: "new-name", policy: .deny)
        XCTAssertEqual(store.entries.count, 1)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.displayName, "new-name")
        XCTAssertEqual(entry.policy, .deny)
        XCTAssertEqual(entry.addedAt, originalAddedAt)
    }

    @MainActor
    func testRemoveDeletesEntryAndPersists() throws {
        let defaults = try makeScratchDefaults()
        let store = ViewerAccessPolicyStore(defaults: defaults)
        store.upsert(stableID: "nAAA", displayName: "alice", policy: .allow)
        store.upsert(stableID: "nBBB", displayName: "bob", policy: .deny)
        store.remove(stableID: "nAAA")

        XCTAssertNil(store.policy(for: "nAAA"))
        XCTAssertEqual(store.entries.map(\.stableID), ["nBBB"])
        let reloaded = ViewerAccessPolicyStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.map(\.stableID), ["nBBB"])
    }

    @MainActor
    func testRefreshDisplayNameRenamesWithoutTouchingPolicy() throws {
        let defaults = try makeScratchDefaults()
        let store = ViewerAccessPolicyStore(defaults: defaults)
        store.upsert(stableID: "nAAA", displayName: "old-hostname", policy: .deny)

        store.refreshDisplayName(stableID: "nAAA", displayName: "renamed-hostname")
        XCTAssertEqual(store.entries.first?.displayName, "renamed-hostname")
        XCTAssertEqual(store.policy(for: "nAAA"), .deny)

        // Unknown peers are a no-op — a sighting must never create an entry.
        store.refreshDisplayName(stableID: "nZZZ", displayName: "stranger")
        XCTAssertEqual(store.entries.count, 1)
    }

    @MainActor
    func testCorruptBlobLoadsAsEmpty() throws {
        let defaults = try makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ViewerAccessPolicyStore.defaultsKey)
        let store = ViewerAccessPolicyStore(defaults: defaults)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPoliciesByStableIDProjection() {
        let entries = [
            PeerAccessEntry(stableID: "nAAA", displayName: "a", policy: .allow, addedAt: Date()),
            PeerAccessEntry(stableID: "nBBB", displayName: "b", policy: .deny, addedAt: Date())
        ]
        let map = ViewerAccessPolicyStore.policiesByStableID(entries)
        XCTAssertEqual(map, ["nAAA": .allow, "nBBB": .deny])
    }

    // MARK: - admissionDecision truth table

    func testAdmissionDecisionTruthTable() {
        typealias Server = TailscaleScreenShareServer
        // Remembered deny wins over everything — including open-door mode.
        XCTAssertEqual(Server.admissionDecision(policy: .deny, requireApproval: true), .reject)
        XCTAssertEqual(Server.admissionDecision(policy: .deny, requireApproval: false), .reject)
        // Remembered allow skips the prompt regardless of the gate.
        XCTAssertEqual(Server.admissionDecision(policy: .allow, requireApproval: true), .admit)
        XCTAssertEqual(Server.admissionDecision(policy: .allow, requireApproval: false), .admit)
        // Unremembered peers follow the gate.
        XCTAssertEqual(Server.admissionDecision(policy: nil, requireApproval: true), .park)
        XCTAssertEqual(Server.admissionDecision(policy: nil, requireApproval: false), .admit)
    }

    // MARK: - drainDecision (setRequireApproval(false) toggle-off drain)

    func testDrainDecisionDeniesBlockedAndApprovesTheRest() {
        let pending: [String: String?] = [
            "1.1.1.1:1": "nALLOWED",
            "2.2.2.2:2": "nBLOCKED",
            "3.3.3.3:3": "nUNKNOWN"
        ]
        let policies: [String: PeerPolicy] = ["nALLOWED": .allow, "nBLOCKED": .deny]
        let decision = TailscaleScreenShareServer.drainDecision(
            pendingStableIDs: pending, policies: policies)
        XCTAssertEqual(decision.approve, ["1.1.1.1:1", "3.3.3.3:3"])
        XCTAssertEqual(decision.deny, ["2.2.2.2:2"])
    }

    func testDrainDecisionUnresolvedStableIDIsApproved() {
        // nil stableID can't match a policy: the drain admits them (the
        // post-resolution deny check still expels a blocked peer later).
        let decision = TailscaleScreenShareServer.drainDecision(
            pendingStableIDs: ["4.4.4.4:4": nil],
            policies: ["nBLOCKED": .deny])
        XCTAssertEqual(decision.approve, ["4.4.4.4:4"])
        XCTAssertTrue(decision.deny.isEmpty)
    }

    func testDrainDecisionEmptyPendingYieldsNothing() {
        let decision = TailscaleScreenShareServer.drainDecision(
            pendingStableIDs: [:], policies: ["nBLOCKED": .deny])
        XCTAssertTrue(decision.approve.isEmpty)
        XCTAssertTrue(decision.deny.isEmpty)
    }

    // MARK: - ViewerApprovalDefaults tri-state migration

    func testApprovalDefaultsUnsetMeansOn() throws {
        let defaults = try makeScratchDefaults()
        XCTAssertTrue(ViewerApprovalDefaults.load(defaults: defaults, environment: [:]))
    }

    func testApprovalDefaultsStoredFalseSticks() throws {
        // A user who explicitly opted out before (or after) the default
        // flip keeps their open-door choice.
        let defaults = try makeScratchDefaults()
        ViewerApprovalDefaults.save(false, defaults: defaults)
        XCTAssertFalse(ViewerApprovalDefaults.load(defaults: defaults, environment: [:]))
    }

    func testApprovalDefaultsStoredTrueSticks() throws {
        let defaults = try makeScratchDefaults()
        ViewerApprovalDefaults.save(true, defaults: defaults)
        XCTAssertTrue(ViewerApprovalDefaults.load(defaults: defaults, environment: [:]))
    }

    func testApprovalDefaultsOpenDoorEnvOverridesEverything() throws {
        let defaults = try makeScratchDefaults()
        ViewerApprovalDefaults.save(true, defaults: defaults)
        let env = [ViewerApprovalDefaults.openDoorEnvKey: "1"]
        XCTAssertFalse(ViewerApprovalDefaults.load(defaults: defaults, environment: env))
    }

    func testApprovalDefaultsOpenDoorEnvMustBeExactlyOne() throws {
        let defaults = try makeScratchDefaults()
        let env = [ViewerApprovalDefaults.openDoorEnvKey: "0"]
        XCTAssertTrue(ViewerApprovalDefaults.load(defaults: defaults, environment: env))
    }
}
