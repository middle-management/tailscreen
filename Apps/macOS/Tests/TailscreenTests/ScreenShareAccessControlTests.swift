import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// End-to-end for the viewer-consent gate over real tsnet transport
/// (pattern of `ScreenShareSyntheticFramesTests` — headless `filterData:
/// nil` server, no capture-helper, no Screen Recording permission).
///
/// One server with `requireApproval` on, three sequential viewers:
///
///   1. **Unknown** — parks pending (no HELLO_ACK), `approveViewer` admits
///      it (regression for the manual Accept path).
///   2. **Remembered allow** — once the pending entry's StableNodeID
///      resolves, pushing an `.allow` policy via `setAccessPolicies`
///      auto-admits it with no manual approve.
///   3. **Remembered deny** — pushing a `.deny` policy rejects it: the
///      viewer's `onDeniedBySharer` fires (HELLO_DENY) and it never enters
///      the connected-viewer roster.
///
/// The StableNodeIDs come from the server's own resolution path (the
/// pending snapshot), exactly like production. Skipped without
/// `TAILSCREEN_TS_AUTHKEY` (run `scripts/e2e-test.sh` for local headscale).
final class ScreenShareAccessControlTests: XCTestCase {

    /// Latest roster snapshots from the server's change callbacks, plus
    /// every connected-viewer addr ever observed (so "never joined" is a
    /// real invariant, not a last-snapshot check).
    private final class RosterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [PendingViewerInfo] = []
        private var viewers: [ViewerInfo] = []
        private var everConnectedAddrs: Set<String> = []

        func setPending(_ snapshot: [PendingViewerInfo]) {
            lock.lock()
            defer { lock.unlock() }
            pending = snapshot
        }

        func setViewers(_ snapshot: [ViewerInfo]) {
            lock.lock()
            defer { lock.unlock() }
            viewers = snapshot
            everConnectedAddrs.formUnion(snapshot.map(\.id))
        }

        var currentPending: [PendingViewerInfo] {
            lock.lock()
            defer { lock.unlock() }
            return pending
        }

        var currentViewerAddrs: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return Set(viewers.map(\.id))
        }

        func everConnected(_ addr: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return everConnectedAddrs.contains(addr)
        }
    }

    private struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Poll `condition` until it returns non-nil or `timeout` elapses;
    /// fails the test and throws on timeout so callers can bail early.
    private func waitFor<T>(
        _ description: String,
        timeout: TimeInterval = 60,
        condition: () -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = condition() { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for: \(description)")
        throw WaitTimeout(description: description)
    }

    func testApprovalGateWithRememberedAllowAndDeny() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(
            testCase: self, label: "access-control",
            names: ["server", "unknown", "allowed", "blocked"])

        let roster = RosterBox()
        let server = TailscaleScreenShareServer()
        server.onPendingViewersChanged = { roster.setPending($0) }
        server.onViewersChanged = { roster.setViewers($0) }
        server.setRequireApproval(true)

        try await server.start(
            hostname: TailscreenE2E.makeHostname("ac-server"),
            authKey: env.authKey,
            path: try XCTUnwrap(dirs["server"]),
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }

        let ips = try await server.getIPAddresses()
        let serverIP = try XCTUnwrap(ips.ip4 ?? ips.ip6, "server has no tailnet IP")

        // ── Phase 1: unknown viewer parks pending; manual approve admits. ──
        let renderer1 = await MainActor.run { MetalViewerRenderer() }
        let client1 = TailscaleScreenShareClient(renderer: renderer1)
        let ack1 = expectation(description: "unknown viewer ACKed after approve")
        ack1.assertForOverFulfill = false
        client1.onAudioSSRCAssigned = { _ in ack1.fulfill() }
        try await client1.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: try XCTUnwrap(dirs["unknown"]),
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client1.disconnect() } }

        let pending1 = try await waitFor("unknown viewer parked pending") {
            roster.currentPending.first
        }
        XCTAssertFalse(
            roster.currentViewerAddrs.contains(pending1.id),
            "pending viewer must not be in the fan-out set before approval")

        server.approveViewer(addr: pending1.id)
        await fulfillment(of: [ack1], timeout: 30)
        _ = try await waitFor("approved viewer joined roster") {
            roster.currentViewerAddrs.contains(pending1.id) ? true : nil
        }
        await client1.disconnect()
        _ = try await waitFor("unknown viewer left after BYE") {
            roster.currentViewerAddrs.contains(pending1.id) ? nil : true
        }

        // ── Phase 2: remembered allow auto-admits without a prompt. ──
        let renderer2 = await MainActor.run { MetalViewerRenderer() }
        let client2 = TailscaleScreenShareClient(renderer: renderer2)
        let ack2 = expectation(description: "allowed viewer auto-ACKed")
        ack2.assertForOverFulfill = false
        client2.onAudioSSRCAssigned = { _ in ack2.fulfill() }
        try await client2.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: try XCTUnwrap(dirs["allowed"]),
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client2.disconnect() } }

        // Wait for the server's own resolution to attach the StableNodeID,
        // then push the allow policy — setAccessPolicies re-evaluates the
        // parked entry and admits it with no approveViewer call.
        let allowed = try await waitFor("allowed viewer resolved a StableNodeID") {
            roster.currentPending.first(where: { $0.stableID != nil })
        }
        let allowedID = try XCTUnwrap(allowed.stableID)
        server.setAccessPolicies([allowedID: .allow])
        await fulfillment(of: [ack2], timeout: 30)
        _ = try await waitFor("allowed viewer joined roster") {
            roster.currentViewerAddrs.contains(allowed.id) ? true : nil
        }
        XCTAssertTrue(
            roster.currentPending.isEmpty,
            "auto-admission must clear the pending row")
        await client2.disconnect()
        _ = try await waitFor("allowed viewer left after BYE") {
            roster.currentViewerAddrs.contains(allowed.id) ? nil : true
        }

        // ── Phase 3: remembered deny rejects with HELLO_DENY. ──
        let renderer3 = await MainActor.run { MetalViewerRenderer() }
        let client3 = TailscaleScreenShareClient(renderer: renderer3)
        let denied = expectation(description: "blocked viewer told it was denied")
        denied.assertForOverFulfill = false
        client3.onDeniedBySharer = { denied.fulfill() }
        try await client3.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: try XCTUnwrap(dirs["blocked"]),
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client3.disconnect() } }

        let blocked = try await waitFor("blocked viewer resolved a StableNodeID") {
            roster.currentPending.first(where: { $0.stableID != nil })
        }
        let blockedID = try XCTUnwrap(blocked.stableID)
        server.setAccessPolicies([allowedID: .allow, blockedID: .deny])
        await fulfillment(of: [denied], timeout: 30)
        XCTAssertFalse(
            roster.everConnected(blocked.id),
            "a denied viewer must never enter the fan-out set")
        _ = try await waitFor("denied viewer's pending row cleared") {
            roster.currentPending.contains(where: { $0.id == blocked.id }) ? nil : true
        }

        await client3.disconnect()
        await server.stop()
    }

    /// The SharingCard's per-row ✕: `disconnectViewer` kicks a *connected*
    /// viewer one-time — HELLO_DENY fires viewer-side (`onDeniedBySharer`),
    /// the roster empties, and NOTHING is remembered: the same node (same
    /// state dir, same StableNodeID) reconnects and parks pending at the
    /// approval gate again, where a fresh approve re-admits it. Distinguishes
    /// the kick from "Deny & Block", whose policy sweep would reject the
    /// re-HELLO outright.
    func testSharerDisconnectIsOneTimeKick() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(
            testCase: self, label: "sharer-kick",
            names: ["server", "viewer"])

        let roster = RosterBox()
        let server = TailscaleScreenShareServer()
        server.onPendingViewersChanged = { roster.setPending($0) }
        server.onViewersChanged = { roster.setViewers($0) }
        server.setRequireApproval(true)

        try await server.start(
            hostname: TailscreenE2E.makeHostname("kick-server"),
            authKey: env.authKey,
            path: try XCTUnwrap(dirs["server"]),
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }

        let ips = try await server.getIPAddresses()
        let serverIP = try XCTUnwrap(ips.ip4 ?? ips.ip6, "server has no tailnet IP")
        let viewerDir = try XCTUnwrap(dirs["viewer"])

        // ── Park, approve, join. ──
        let renderer1 = await MainActor.run { MetalViewerRenderer() }
        let client1 = TailscaleScreenShareClient(renderer: renderer1)
        let ack1 = expectation(description: "viewer ACKed after approve")
        ack1.assertForOverFulfill = false
        client1.onAudioSSRCAssigned = { _ in ack1.fulfill() }
        let denied = expectation(description: "kicked viewer told via HELLO_DENY")
        denied.assertForOverFulfill = false
        client1.onDeniedBySharer = { denied.fulfill() }
        try await client1.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: viewerDir,
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client1.disconnect() } }

        let pending = try await waitFor("viewer parked pending") {
            roster.currentPending.first
        }
        server.approveViewer(addr: pending.id)
        await fulfillment(of: [ack1], timeout: 30)
        _ = try await waitFor("approved viewer joined roster") {
            roster.currentViewerAddrs.contains(pending.id) ? true : nil
        }

        // ── Kick: viewer learns it was disconnected, roster empties. ──
        server.disconnectViewer(addr: pending.id)
        await fulfillment(of: [denied], timeout: 30)
        _ = try await waitFor("kicked viewer left the roster") {
            roster.currentViewerAddrs.contains(pending.id) ? nil : true
        }
        // Free the state dir (and its node identity) for the reconnect.
        await client1.disconnect()

        // ── Same node identity comes back: parks pending (not rejected),
        //    and a fresh approve re-admits it. ──
        let renderer2 = await MainActor.run { MetalViewerRenderer() }
        let client2 = TailscaleScreenShareClient(renderer: renderer2)
        let ack2 = expectation(description: "returning viewer ACKed after re-approve")
        ack2.assertForOverFulfill = false
        client2.onAudioSSRCAssigned = { _ in ack2.fulfill() }
        try await client2.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: viewerDir,
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client2.disconnect() } }

        let reparked = try await waitFor("returning viewer parked pending again") {
            roster.currentPending.first
        }
        server.approveViewer(addr: reparked.id)
        await fulfillment(of: [ack2], timeout: 30)
        _ = try await waitFor("returning viewer re-joined roster") {
            roster.currentViewerAddrs.contains(reparked.id) ? true : nil
        }

        await client2.disconnect()
        await server.stop()
    }
}
