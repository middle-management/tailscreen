import AppKit
import Foundation
import TailscaleKit
import XCTest
import os

@testable import Tailscreen

/// Local-only end-to-end: spawns the real `--capture-helper` child against the
/// main display, sends frames over real tsnet transport, and asserts the
/// viewer's `MetalViewerRenderer` reports a non-zero video size (= a frame
/// decoded). GitHub Actions macOS runners can't grant Screen Recording TCC,
/// can't host a real display, and `SCStream` won't come up, so this test
/// self-skips when it sees the CI environment.
///
/// First-time run prompts macOS for Screen Recording permission on the
/// `.build/<config>/Tailscreen` binary (the capture-helper subprocess is the
/// one prompting — `SCShareableContent` is never called in the test process,
/// only in the helper). Subsequent runs are unattended.
///
/// Requirements:
///   - macOS host with a real display and the build at `.build/debug/Tailscreen`
///     (run `make build` first).
///   - `TAILSCREEN_TS_AUTHKEY` (or local headscale via `scripts/e2e-up.sh`).
///   - Screen Recording permission granted to `.build/debug/Tailscreen`.
final class ScreenShareCaptureHelperTests: XCTestCase {
    func testFullPipelineCapturesMainDisplay() async throws {
        try TailscreenE2E.skipCaptureTestOnCI()

        let envCfg = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "capture-helper")
        try TailscreenE2E.overrideHelperExecutable(testCase: self)
        let filterData = try TailscreenE2E.mainDisplayFilterData()

        let server = TailscaleScreenShareServer()
        try await server.start(
            hostname: TailscreenE2E.makeHostname("cap-server"),
            authKey: envCfg.authKey,
            path: dirs.server,
            controlURL: envCfg.controlURL,
            filterData: filterData
        )
        addTeardownBlock { Task { await server.stop() } }

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        let renderer = await MainActor.run { MetalViewerRenderer() }
        let client = TailscaleScreenShareClient(renderer: renderer)

        // Exercise the REAL render path: host the renderer's CAMetalLayer in an
        // on-screen NSWindow and call start(in:) so its CADisplayLink ticks.
        // onVideoSizeChanged fires from the display-link-driven render() — the
        // same present path production uses. (This is why the test is local-
        // only: a headless CI runner has no screen for the link to attach to.)
        let firstFrame = expectation(description: "viewer rendered a frame")
        firstFrame.assertForOverFulfill = false
        let window = await MainActor.run { () -> NSWindow in
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let host = NSView(frame: win.contentView?.bounds ?? .zero)
            host.wantsLayer = true
            host.layer = CALayer()
            host.layer?.addSublayer(renderer.metalLayer)
            win.contentView?.addSubview(host)
            win.orderFrontRegardless()
            renderer.onVideoSizeChanged = { size in
                if size.width > 0, size.height > 0 { firstFrame.fulfill() }
            }
            renderer.start(in: host)
            return win
        }
        addTeardownBlock { Task { @MainActor in window.orderOut(nil) } }

        try await client.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: envCfg.authKey,
            path: dirs.client,
            controlURL: envCfg.controlURL
        )
        addTeardownBlock { Task { await client.disconnect() } }

        // Keep ScreenCaptureKit delivering frames on a static screen until
        // the viewer decodes one (see TailscreenE2E.startCursorJiggle).
        let jiggle = TailscreenE2E.startCursorJiggle(testCase: self)

        // 30 s ceiling: SCStream startup, first keyframe, tsnet propagation,
        // RTP delivery, decode, display-link render. Loose enough to absorb a
        // cold machine without letting a real regression hide.
        await fulfillment(of: [firstFrame], timeout: 30)
        jiggle.cancel()

        await client.disconnect()
        await server.stop()
    }

    /// Mid-share source switch over the full pipeline: real capture-helper,
    /// real tsnet transport, one connected viewer. After the first decoded
    /// frame, `server.changeSource(filterData:)` retargets capture — a
    /// same-target switch back to the main display, which is deterministic
    /// on a one-display Mac while still exercising the full stop-helper →
    /// respawn → fresh-IDR path — and the test asserts (1) the viewer
    /// resumes decoding after the swap and (2) `onCaptureStopped` never
    /// fired (the share survived). Local-only, like its sibling above.
    func testChangeSourceRestartsCaptureWithoutDroppingViewer() async throws {
        try TailscreenE2E.skipCaptureTestOnCI()

        let envCfg = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "change-source")
        try TailscreenE2E.overrideHelperExecutable(testCase: self)
        let filterData = try TailscreenE2E.mainDisplayFilterData()

        let server = TailscaleScreenShareServer()
        // The share must survive the switch: any capture-stop callback
        // (user stop, crash budget exhausted, respawn failure) is a
        // failure of the retarget path.
        let captureStopped = OSAllocatedUnfairLock(initialState: false)
        server.onCaptureStopped = { _ in captureStopped.withLock { $0 = true } }
        try await server.start(
            hostname: TailscreenE2E.makeHostname("chsrc-server"),
            authKey: envCfg.authKey,
            path: dirs.server,
            controlURL: envCfg.controlURL,
            filterData: filterData
        )
        addTeardownBlock { Task { await server.stop() } }

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        let renderer = await MainActor.run { MetalViewerRenderer() }
        let client = TailscaleScreenShareClient(renderer: renderer)

        let decodedBefore = expectation(description: "viewer decoded a frame before the switch")
        decodedBefore.assertForOverFulfill = false
        client.onDecodedFrameForTesting = { _ in decodedBefore.fulfill() }

        try await client.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: envCfg.authKey,
            path: dirs.client,
            controlURL: envCfg.controlURL
        )
        addTeardownBlock { Task { await client.disconnect() } }

        // Keep ScreenCaptureKit delivering frames on a static screen —
        // same cursor jiggle as the sibling test.
        let jiggle = TailscreenE2E.startCursorJiggle(testCase: self)

        await fulfillment(of: [decodedBefore], timeout: 30)

        // Retarget. Same selection bytes — the helper re-resolves the IDs
        // independently, so this runs the identical respawn machinery a
        // window→display switch would.
        let retargeted = try await server.changeSource(filterData: filterData)
        XCTAssertTrue(retargeted, "changeSource reported the server as not running mid-share")

        // Install the post-switch expectation only after changeSource
        // returned: the old helper is already dead by then, so any decode
        // from here on proves the fresh helper's stream reached the viewer.
        let decodedAfter = expectation(description: "viewer decoded a frame after the switch")
        decodedAfter.assertForOverFulfill = false
        client.onDecodedFrameForTesting = { _ in decodedAfter.fulfill() }

        await fulfillment(of: [decodedAfter], timeout: 30)
        jiggle.cancel()

        XCTAssertFalse(
            captureStopped.withLock { $0 },
            "onCaptureStopped fired during a source switch — the share should have survived")

        await client.disconnect()
        await server.stop()
    }
}
