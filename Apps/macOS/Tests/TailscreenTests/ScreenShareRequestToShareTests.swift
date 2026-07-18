import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// End-to-end for the peer-to-peer "request to share" prompt and its
/// accept/decline round-trip. One node stands up a
/// `TailscreenControlListener` (the long-lived control listener AppState
/// owns in production); another node sends a request via
/// `TailscreenMetadataService.sendRequestToShareAwaitingResponse`. Asserts
/// the listener's `onRequestToShare` fires with the requester's hostname
/// and that a `.shareResponse` sent back on the same connection reaches the
/// requester as `.accepted` / `.declined` (silence ⇒ `.noAnswer`) — no UI,
/// no notifications.
///
/// Uses two raw tsnet nodes (not the screen-share server/client) because
/// request-to-share is independent of an active share. Skipped without
/// `TAILSCREEN_TS_AUTHKEY`.
final class ScreenShareRequestToShareTests: XCTestCase {

    private struct Peers {
        let sharerNode: TailscaleNode
        let requesterNode: TailscaleNode
        let listener: TailscreenControlListener
        let sharerIP: String
    }

    /// Shared bring-up: sharer node + control listener, requester node.
    private func bringUpPeers(label: String, logger: ReqLogger) async throws -> Peers {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(
            testCase: self, label: label, names: ["sharer", "requester"])
        let sharerDir = try XCTUnwrap(dirs["sharer"])
        let requesterDir = try XCTUnwrap(dirs["requester"])

        let sharerNode = try TailscaleNode(
            config: Configuration(
                hostName: TailscreenE2E.makeHostname("rts-sharer"),
                path: sharerDir,
                authKey: env.authKey,
                controlURL: env.controlURL,
                ephemeral: true
            ),
            logger: logger
        )
        try await sharerNode.up()
        addTeardownBlock { try? await sharerNode.close() }

        let listener = TailscreenControlListener()
        try await listener.start(node: sharerNode)
        addTeardownBlock { await listener.stop() }

        let sharerIPs = try await sharerNode.addrs()
        let sharerIP = try XCTUnwrap(sharerIPs.ip4 ?? sharerIPs.ip6, "sharer node has no tailnet IP")

        let requesterNode = try TailscaleNode(
            config: Configuration(
                hostName: TailscreenE2E.makeHostname("rts-requester"),
                path: requesterDir,
                authKey: env.authKey,
                controlURL: env.controlURL,
                ephemeral: true
            ),
            logger: logger
        )
        try await requesterNode.up()
        addTeardownBlock { try? await requesterNode.close() }

        return Peers(
            sharerNode: sharerNode, requesterNode: requesterNode,
            listener: listener, sharerIP: sharerIP)
    }

    /// Netmap propagation can lag just after up(); retry the dial.
    private func sendWithRetries(
        peers: Peers,
        from requesterName: String,
        responseTimeout: TimeInterval,
        logger: ReqLogger
    ) async throws -> ShareRequestOutcome {
        let metadata = await MainActor.run { TailscreenMetadataService() }
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                return try await metadata.sendRequestToShareAwaitingResponse(
                    toIP: peers.sharerIP,
                    port: NetworkConfig.tailscreenPort,
                    from: requesterName,
                    via: peers.requesterNode,
                    responseTimeout: responseTimeout
                )
            } catch {
                lastError = error
                logger.log("sendRequestToShare attempt \(attempt) failed: \(error); retrying")
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError ?? TimeoutError()
    }

    func testRequestReachesListenerAndSilenceReadsAsNoAnswer() async throws {
        let logger = ReqLogger()
        let peers = try await bringUpPeers(label: "req-to-share", logger: logger)

        let gotRequest = expectation(description: "listener received request-to-share")
        gotRequest.assertForOverFulfill = false
        let requesterName = "requester-\(UUID().uuidString.prefix(6))"
        peers.listener.onRequestToShare = { hostname, _, _ in
            if hostname == requesterName { gotRequest.fulfill() }
        }

        // The listener never answers — the requester's await must settle
        // to .noAnswer after its (short, test-tuned) response timeout.
        // This is also exactly what an old peer without shareResponse
        // support produces.
        let outcome = try await sendWithRetries(
            peers: peers, from: requesterName, responseTimeout: 5, logger: logger)
        XCTAssertEqual(outcome, .noAnswer)

        await fulfillment(of: [gotRequest], timeout: 10)
    }

    func testAcceptAndDeclineRoundTripOnSameConnection() async throws {
        let logger = ReqLogger()
        let peers = try await bringUpPeers(label: "req-response", logger: logger)
        let listener = peers.listener

        // First request → accept, second → decline, both answered on the
        // connection the request arrived on (the production path — see
        // AppState.respondToShareRequest).
        let accepts = FirstAcceptThenDeclineFlag(true)
        listener.onRequestToShare = { [weak listener] _, connectionID, _ in
            let accepted = accepts.getAndClear()
            Task { [weak listener] in
                await listener?.send(.shareResponse(accepted: accepted), to: connectionID)
            }
        }

        let requesterName = "requester-\(UUID().uuidString.prefix(6))"
        let first = try await sendWithRetries(
            peers: peers, from: requesterName, responseTimeout: 30, logger: logger)
        XCTAssertEqual(first, .accepted)

        let second = try await sendWithRetries(
            peers: peers, from: requesterName, responseTimeout: 30, logger: logger)
        XCTAssertEqual(second, .declined)
    }
}

/// Tiny lock-guarded flag: first read returns the seeded value, later
/// reads return false. Lets the (Sendable, off-main) listener callback
/// hand out "accept first, decline afterwards" without data races.
private final class FirstAcceptThenDeclineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func getAndClear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let v = value
        value = false
        return v
    }
}

private struct ReqLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) { print("[rts-test] \(message)") }
}
