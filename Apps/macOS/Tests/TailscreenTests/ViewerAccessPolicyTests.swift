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

    func testAdmissionDecisionGuestsAlwaysPark() {
        typealias Server = TailscaleScreenShareServer
        // A guest (share-by-token viewer) never auto-admits: the token is
        // capability to knock, never to watch. Open-door mode and even a
        // remembered allow still park them behind the prompt.
        XCTAssertEqual(
            Server.admissionDecision(policy: nil, requireApproval: false, isGuest: true), .park)
        XCTAssertEqual(
            Server.admissionDecision(policy: nil, requireApproval: true, isGuest: true), .park)
        XCTAssertEqual(
            Server.admissionDecision(policy: .allow, requireApproval: false, isGuest: true), .park)
        // A deny still rejects outright.
        XCTAssertEqual(
            Server.admissionDecision(policy: .deny, requireApproval: false, isGuest: true), .reject)
        // And the default keeps tailnet behavior byte-identical.
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

    func testDrainDecisionLeavesGuestsParked() {
        // Toggling the gate off opens the door to the tailnet, not to
        // token holders: a parked guest is neither approved nor denied.
        let pending: [String: String?] = [
            "1.1.1.1:1": "nALLOWED",
            "[fd7a::42]:7447": nil  // guest — addr came off the guest listener
        ]
        let decision = TailscaleScreenShareServer.drainDecision(
            pendingStableIDs: pending,
            policies: ["nALLOWED": .allow],
            guestAddrs: ["[fd7a::42]:7447"])
        XCTAssertEqual(decision.approve, ["1.1.1.1:1"])
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

    // Queued "Always Allow" / "Deny & Block" intents applied on late
    // StableNodeID resolution used to live here, against `AppState`'s own
    // `resolvableIntents`. That copy is gone: `AppState` now holds the SHARED
    // `ViewerRosterDecision.PendingIntents` the GTK and WinUI hosts hold, so
    // the rule is pinned once, portably, by `ViewerPendingIntentsTests` in the
    // package's `TailscreenProtocolTests` — including the two legs macOS never
    // had, last-write-wins and prune-on-departure.

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
