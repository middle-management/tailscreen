import CoreVideo
import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// End-to-end: server (no capture-helper) → RTP → real tsnet transport → client
/// → `VideoDecoder` → `MetalViewerRenderer`. Synthetic AVCC bytes generated in
/// the test process via `VideoEncoder`, so this is fast and deterministic and
/// doesn't need Screen Recording permission or a real display.
///
/// Skipped without `TAILSCREEN_TS_AUTHKEY` (run `scripts/e2e-test.sh` for local
/// headscale). Also self-skips if VideoToolbox produces no output (virtualized
/// CI runners with no paravirt video driver).
final class ScreenShareSyntheticFramesTests: XCTestCase {
    func testServerBroadcastsSyntheticFramesAndClientDecodes() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "synth-frames")

        // Encode ~30 frames of a synthetic CVPixelBuffer to get realistic
        // AVCC NAL units + parameter sets to inject.
        let synth = try await TailscreenE2E.encodeSyntheticAUs()
        let params = synth.params

        // Bring up a server with filterData: nil (no SCStream spawn).
        let server = TailscaleScreenShareServer()
        let serverHostname = TailscreenE2E.makeHostname("synth-server")
        try await server.start(
            hostname: serverHostname,
            authKey: env.authKey,
            path: dirs.server,
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }

        // Seed the codec + parameter sets the broadcast path expects. In
        // production these come in via the capture-helper's parameter-sets
        // callback; without a helper we have to inject them ourselves.
        server.injectSyntheticParameters(params)

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        // Bring up a viewer-side client + renderer.
        let renderer = await MainActor.run { MetalViewerRenderer() }
        let client = TailscaleScreenShareClient(renderer: renderer)
        let assignedAck = expectation(description: "HELLO_ACK assigned by server")
        client.onAudioSSRCAssigned = { _ in assignedAck.fulfill() }
        try await client.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: dirs.client,
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client.disconnect() } }
        await fulfillment(of: [assignedAck], timeout: 30)

        // Assert on decode, not render: the renderer only presents frames once
        // its CADisplayLink is driving, and that link needs an on-screen NSView
        // (MetalViewerRenderer.start(in:)) which doesn't exist under xctest.
        // onDecodedFrameForTesting fires on the decoder output thread.
        let frameReceived = expectation(description: "client decoded a frame")
        frameReceived.assertForOverFulfill = false
        client.onDecodedFrameForTesting = { _ in frameReceived.fulfill() }

        // Drive the server's broadcast path. Force the first AU to be flagged
        // as a keyframe so the parameter sets are prepended on the wire and
        // the client decoder can configure itself.
        for (i, au) in synth.aus.enumerated() {
            server.broadcastForTesting(avccData: au.data, isKeyframe: i == 0 || au.isKey)
            try await Task.sleep(for: .milliseconds(33))  // ~30 fps
        }

        await fulfillment(of: [frameReceived], timeout: 10)

        await client.disconnect()
        await server.stop()
    }

    /// Mid-stream source/resolution change, viewer side. A "Change
    /// Source…" retarget is (to the viewer) just a fresh encoder emitting
    /// an IDR with new in-band parameter sets — this proves the client
    /// re-installs the params, rebuilds its decoder, and decodes frames at
    /// the new dimensions with zero out-of-band signaling, using no
    /// capture machinery at all. Mirrors what
    /// `TailscaleScreenShareServer.changeSource` produces after the helper
    /// respawn.
    func testClientAdaptsToMidStreamResolutionChange() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "synth-reschange")

        // Two synthetic streams at different dimensions — "before" and
        // "after" the source switch.
        let synthBefore = try await TailscreenE2E.encodeSyntheticAUs(width: 640, height: 360)
        let synthAfter = try await TailscreenE2E.encodeSyntheticAUs(width: 960, height: 540)

        let server = TailscaleScreenShareServer()
        try await server.start(
            hostname: TailscreenE2E.makeHostname("resw-server"),
            authKey: env.authKey,
            path: dirs.server,
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }
        server.injectSyntheticParameters(synthBefore.params)

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        let renderer = await MainActor.run { MetalViewerRenderer() }
        let client = TailscaleScreenShareClient(renderer: renderer)
        let assignedAck = expectation(description: "HELLO_ACK assigned by server")
        client.onAudioSSRCAssigned = { _ in assignedAck.fulfill() }
        try await client.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: env.authKey,
            path: dirs.client,
            controlURL: env.controlURL
        )
        addTeardownBlock { Task { await client.disconnect() } }
        await fulfillment(of: [assignedAck], timeout: 30)

        let decodedOld = expectation(description: "client decoded a 640x360 frame")
        decodedOld.assertForOverFulfill = false
        let decodedNew = expectation(description: "client decoded a 960x540 frame")
        decodedNew.assertForOverFulfill = false
        client.onDecodedFrameForTesting = { buffer in
            let width = CVPixelBufferGetWidth(buffer)
            if width == 640 { decodedOld.fulfill() }
            if width == 960 { decodedNew.fulfill() }
        }

        // Phase 1: old dimensions decode.
        for (i, au) in synthBefore.aus.enumerated() {
            server.broadcastForTesting(avccData: au.data, isKeyframe: i == 0 || au.isKey)
            try await Task.sleep(for: .milliseconds(33))
        }
        await fulfillment(of: [decodedOld], timeout: 10)

        // Phase 2: swap the cached parameter sets — exactly what the fresh
        // helper's onParameterSets callback does after a changeSource
        // respawn — and broadcast the new stream, first AU keyframed so the
        // new params ship in-band immediately.
        server.injectSyntheticParameters(synthAfter.params)
        for (i, au) in synthAfter.aus.enumerated() {
            server.broadcastForTesting(avccData: au.data, isKeyframe: i == 0 || au.isKey)
            try await Task.sleep(for: .milliseconds(33))
        }
        await fulfillment(of: [decodedNew], timeout: 10)

        await client.disconnect()
        await server.stop()
    }
}
