import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen

/// End-to-end for the opt-in remote-control grant flow over real tsnet
/// transport (pattern of `ScreenShareControlChannelTests` — headless
/// `filterData: nil` server, no capture-helper, no Screen Recording or
/// Accessibility permission). One admitted viewer:
///
///   1. `requestControl()` → the server's `onControlRequestsChanged` surfaces
///      the request with its connection UUID.
///   2. Input sent *before* a grant is dropped — the gate's authoritative
///      server-side check (`onInputEventForTesting` never fires).
///   3. `grantControl` (Accessibility check bypassed for xctest) → the
///      viewer's `onControlGranted` fires and the sharer's grant snapshot
///      updates.
///   4. Input sent *after* the grant passes the gate (`onInputEventForTesting`
///      fires) — no real `CGEventPost` (the injector has no selection).
///   5. `revokeControl` → the viewer's `onControlRevoked` fires.
///
/// Real injection needs the sharer's Accessibility TCC grant and is
/// manual/local-only. Skipped without `TAILSCREEN_TS_AUTHKEY`.
final class ScreenShareRemoteControlTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: UUID?
        private var inputCount = 0

        func setRequestID(_ id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            if requestID == nil { requestID = id }
        }

        var currentRequestID: UUID? {
            lock.lock()
            defer { lock.unlock() }
            return requestID
        }

        func bumpInput() {
            lock.lock()
            defer { lock.unlock() }
            inputCount += 1
        }

        var currentInputCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return inputCount
        }
    }

    func testGrantFlowAndInputGate() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "remote-control")
        let box = Box()

        let server = TailscaleScreenShareServer()
        server.grantBypassesAccessibilityForTesting = true

        // Route the @Sendable roster callback through the box (never capture
        // an XCTestExpectation in it — same discipline as the other E2E
        // suites); the request is observed by polling below.
        server.onControlRequestsChanged = { requests in
            if let first = requests.first { box.setRequestID(first.id) }
        }
        server.onInputEventForTesting = { _ in box.bumpInput() }

        try await server.start(
            hostname: TailscreenE2E.makeHostname("rc-server"),
            authKey: env.authKey,
            path: dirs.server,
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        let renderer = await MainActor.run { MetalViewerRenderer() }
        let client = TailscaleScreenShareClient(renderer: renderer)

        // Wait for HELLO_ACK so the viewer is admitted — a control request from
        // a non-admitted peer is dropped server-side.
        let registered = expectation(description: "viewer registered")
        client.onAudioSSRCAssigned = { _ in registered.fulfill() }
        let granted = expectation(description: "viewer received controlGranted")
        client.onControlGranted = { granted.fulfill() }
        let revoked = expectation(description: "viewer received controlRevoked")
        client.onControlRevoked = { _ in revoked.fulfill() }

        try await client.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: dirs.client, controlURL: env.controlURL)
        addTeardownBlock { Task { await client.disconnect() } }
        await fulfillment(of: [registered], timeout: 30)

        // Let the TCP back-channel come up.
        try await Task.sleep(for: .milliseconds(500))

        // Input before any grant must be dropped by the server gate.
        await client.sendInputEvent(.mouseMove(x: 0.5, y: 0.5))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(box.currentInputCount, 0, "input before a grant must be dropped")

        // Request control (TCP; resend and poll for the server to surface it).
        var observedID: UUID?
        for _ in 0..<25 {
            await client.requestControl()
            if let id = box.currentRequestID {
                observedID = id
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let connectionID = try XCTUnwrap(observedID, "server never surfaced the control request")
        XCTAssertTrue(server.grantControl(toConnectionID: connectionID))
        await fulfillment(of: [granted], timeout: 10)

        // Input after the grant passes the gate.
        for _ in 0..<5 {
            await client.sendInputEvent(.mouseMove(x: 0.4, y: 0.6))
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertGreaterThan(box.currentInputCount, 0, "granted input must pass the gate")

        server.revokeControl(reason: "test")
        await fulfillment(of: [revoked], timeout: 10)

        await client.disconnect()
        await server.stop()
    }
}
