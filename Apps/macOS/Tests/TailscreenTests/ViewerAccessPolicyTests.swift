import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// Unit tests for the viewer-consent machinery that runs without tsnet:
/// the persistent per-peer allow/deny store (`ViewerAccessPolicyStore`) and
/// the pure admission gate extracted from the server
/// (`admissionDecision` / `drainDecision` — same pattern as
/// `ViewerLifecycleDecisionTests`). The tri-state default migration lives in
/// the portable `ViewerApprovalPreference`, covered by the package's
/// `ViewerApprovalPreferenceTests`.
final class ViewerAccessPolicyTests: XCTestCase {

    /// Scratch `UserDefaults` suite, wiped on teardown so runs don't
    /// contaminate each other (or the developer's real defaults).
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "viewer-access-policy-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        // Capture only the Sendable suite name — capturing `defaults` (a
        // non-Sendable value the caller also uses) in the teardown closure
        // trips Swift 6's sending-risks-data-race check. `removePersistentDomain`
        // clears the named domain from any instance.
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
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

    // MARK: - connectedDenyList (policy→deny sweep of the connected roster)

    func testConnectedDenyListPicksResolvedBlockedViewers() {
        let connected: [String: String?] = [
            "1.1.1.1:1": "nALLOWED",
            "2.2.2.2:2": "nBLOCKED",
            "3.3.3.3:3": nil,  // unresolved — can't match a policy
            "4.4.4.4:4": "nBLOCKED"
        ]
        let policies: [String: PeerPolicy] = ["nALLOWED": .allow, "nBLOCKED": .deny]
        let expelled = TailscaleScreenShareServer.connectedDenyList(
            viewerStableIDs: connected, policies: policies)
        XCTAssertEqual(expelled, ["2.2.2.2:2", "4.4.4.4:4"])
    }

    func testConnectedDenyListEmptyWhenNoDenies() {
        let expelled = TailscaleScreenShareServer.connectedDenyList(
            viewerStableIDs: ["1.1.1.1:1": "nALLOWED"], policies: ["nALLOWED": .allow])
        XCTAssertTrue(expelled.isEmpty)
    }

    // MARK: - pending cap (DoS bound)

    func testPendingCapRejectsNewOnceFull() {
        typealias Server = TailscaleScreenShareServer
        // A brand-new addr is rejected at/above the cap…
        XCTAssertFalse(Server.canAcceptPending(currentCount: 3, isExisting: false, cap: 3))
        XCTAssertFalse(Server.canAcceptPending(currentCount: 4, isExisting: false, cap: 3))
        // …but an existing slot (a re-HELLO) always refreshes…
        XCTAssertTrue(Server.canAcceptPending(currentCount: 3, isExisting: true, cap: 3))
        // …and there's room below the cap.
        XCTAssertTrue(Server.canAcceptPending(currentCount: 2, isExisting: false, cap: 3))
    }

    // MARK: - queued policy intents applied on late StableNodeID resolution

    @MainActor
    func testResolvableIntentsMatchesOnlyResolvedRowsWithIntent() {
        let intents: [String: PeerPolicy] = ["1.1.1.1:1": .deny, "2.2.2.2:2": .allow]
        let snapshot: [(id: String, stableID: String?)] = [
            ("1.1.1.1:1", "nBLOCKED"),  // intent + resolved → applied
            ("2.2.2.2:2", nil),  // intent but unresolved → skipped
            ("3.3.3.3:3", "nOTHER")  // resolved but no intent → skipped
        ]
        let resolvable = AppState.resolvableIntents(intents: intents, snapshot: snapshot)
        XCTAssertEqual(resolvable.count, 1)
        let item = try? XCTUnwrap(resolvable.first)
        XCTAssertEqual(item?.id, "1.1.1.1:1")
        XCTAssertEqual(item?.stableID, "nBLOCKED")
        XCTAssertEqual(item?.policy, .deny)
    }

    @MainActor
    func testResolvableIntentsEmptyWhenNothingQueued() {
        let resolvable = AppState.resolvableIntents(
            intents: [:], snapshot: [("1.1.1.1:1", "nX")])
        XCTAssertTrue(resolvable.isEmpty)
    }

    // MARK: - readFailed classification reuse (awaitShareResponse dead-socket)

    func testReadFailedClassificationDistinguishesDeadSocketFromPollTimeout() {
        // `awaitShareResponse` reuses this exact classifier so a dead/closed
        // connection returns .noAnswer instead of hot-spinning the full
        // 120 s: a near-instant readFailed is a dead fd, a full-interval one
        // (its 5 s poll) is a benign timeout.
        XCTAssertTrue(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 1_000_000))  // 1 ms → dead
        XCTAssertFalse(ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: 5_000_000_000))  // 5 s → timeout
    }

}
