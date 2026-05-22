import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen

/// End-to-end for the peer-to-peer "request to share" prompt. One node stands
/// up a `TailscreenControlListener` (the long-lived control listener AppState
/// owns in production); another node sends a request via
/// `TailscreenMetadataService.sendRequestToShare`. Asserts the listener's
/// `onRequestToShare` fires with the requester's hostname — no UI, no
/// notifications.
///
/// Uses two raw tsnet nodes (not the screen-share server/client) because
/// request-to-share is independent of an active share. Skipped without
/// `TAILSCREEN_TS_AUTHKEY`.
final class ScreenShareRequestToShareTests: XCTestCase {
    func testRequestToShareReachesListener() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(
            testCase: self, label: "req-to-share", names: ["sharer", "requester"])
        let sharerDir = try XCTUnwrap(dirs["sharer"])
        let requesterDir = try XCTUnwrap(dirs["requester"])
        let logger = ReqLogger()

        // ── Sharer side: bring up a node + control listener. ──
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
        let gotRequest = expectation(description: "listener received request-to-share")
        gotRequest.assertForOverFulfill = false
        let requesterName = "requester-\(UUID().uuidString.prefix(6))"
        listener.onRequestToShare = { hostname in
            if hostname == requesterName { gotRequest.fulfill() }
        }
        try await listener.start(node: sharerNode)
        addTeardownBlock { await listener.stop() }

        let sharerIPs = try await sharerNode.addrs()
        guard let sharerIP = sharerIPs.ip4 ?? sharerIPs.ip6 else {
            XCTFail("sharer node has no tailnet IP")
            return
        }

        // ── Requester side: bring up a node + metadata service. ──
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

        let metadata = await MainActor.run { TailscreenMetadataService() }

        // Netmap propagation can lag just after up(); retry the one-shot dial.
        var sent = false
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                try await metadata.sendRequestToShare(
                    toIP: sharerIP,
                    port: NetworkConfig.tailscreenPort,
                    from: requesterName,
                    via: requesterNode
                )
                sent = true
                break
            } catch {
                lastError = error
                logger.log("sendRequestToShare attempt \(attempt) failed: \(error); retrying")
                try await Task.sleep(for: .seconds(1))
            }
        }
        XCTAssertTrue(sent, "request-to-share never sent: \(String(describing: lastError))")

        await fulfillment(of: [gotRequest], timeout: 10)

        await listener.stop()
        try await sharerNode.close()
        try await requesterNode.close()
    }
}

private struct ReqLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) { print("[rts-test] \(message)") }
}
