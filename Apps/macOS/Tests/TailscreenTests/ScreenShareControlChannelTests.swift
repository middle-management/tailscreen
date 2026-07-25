import CoreGraphics
import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// End-to-end for the viewer→sharer control paths that ride alongside video:
///
///   1. **Annotations** (TCP back-channel) — a viewer's `sendAnnotationOp`
///      reaches the sharer's `onAnnotationReceived` with the op intact.
///   2. **PLI** (UDP control) — a viewer's PLI is recorded by the server
///      (observed via the test-only `onPLIRecordedForTesting` seam, since no
///      capture-helper is attached to act on the keyframe request).
///
/// Headless: server runs with `filterData: nil`, no SCStream, no Screen
/// Recording permission. Skipped without `TAILSCREEN_TS_AUTHKEY`.
final class ScreenShareControlChannelTests: XCTestCase {
    func testAnnotationReachesSharer() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "annotations")

        let server = TailscaleScreenShareServer()
        let received = expectation(description: "sharer received annotation op")
        received.assertForOverFulfill = false
        let sentID = UUID()
        server.onAnnotationReceived = { op in
            if case .add(let ann) = op, ann.id == sentID {
                received.fulfill()
            }
        }

        try await server.start(
            hostname: TailscreenE2E.makeHostname("anno-server"),
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
        try await client.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: dirs.client, controlURL: env.controlURL)
        addTeardownBlock { Task { await client.disconnect() } }

        // The annotation back-channel is a best-effort TCP connection opened
        // during connect(); give it a moment to come up before sending.
        try await Task.sleep(for: .milliseconds(500))

        let ann = Annotation(
            id: sentID,
            tool: .pen,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)],
            color: Annotation.defaultColor,
            width: Annotation.defaultWidth
        )
        // TCP is reliable, but resend a couple of times in case the channel
        // wasn't fully established on the first try.
        for _ in 0..<5 {
            await client.sendAnnotationOp(.add(ann))
            try await Task.sleep(for: .milliseconds(200))
        }

        await fulfillment(of: [received], timeout: 10)
        await client.disconnect()
        await server.stop()
    }

    func testViewerPLIRecordedByServer() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "pli")

        let server = TailscaleScreenShareServer()
        let pliRecorded = expectation(description: "server recorded a PLI")
        pliRecorded.assertForOverFulfill = false
        server.onPLIRecordedForTesting = { _ in pliRecorded.fulfill() }

        try await server.start(
            hostname: TailscreenE2E.makeHostname("pli-server"),
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
        // Wait for HELLO_ACK so the server has a registered viewer entry — PLI
        // for an unregistered addr is dropped (recordPLI guards on the entry).
        let registered = expectation(description: "viewer registered")
        client.onAudioSSRCAssigned = { _ in registered.fulfill() }
        try await client.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: dirs.client, controlURL: env.controlURL)
        addTeardownBlock { Task { await client.disconnect() } }
        await fulfillment(of: [registered], timeout: 30)

        // UDP — resend a few times so one dropped datagram doesn't fail it.
        for _ in 0..<10 {
            await client.sendPLIForTesting()
            try await Task.sleep(for: .milliseconds(100))
        }
        await fulfillment(of: [pliRecorded], timeout: 10)

        await client.disconnect()
        await server.stop()
    }
}
