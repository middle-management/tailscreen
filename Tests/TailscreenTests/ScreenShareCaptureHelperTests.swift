import AppKit
import CoreGraphics
import Foundation
import TailscaleKit
import XCTest

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
        // Self-skip in obvious CI; `TAILSCREEN_ALLOW_CAPTURE_TEST=1` is an
        // explicit opt-in for the user to force the test locally without
        // having to remove the CI env vars from their shell.
        let env = ProcessInfo.processInfo.environment
        if env["TAILSCREEN_ALLOW_CAPTURE_TEST"] != "1" {
            try XCTSkipIf(
                env["CI"] == "true" || env["GITHUB_ACTIONS"] == "true",
                "Capture-helper test needs real display + Screen Recording TCC; not viable on CI."
            )
        }

        let envCfg = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(testCase: self, label: "capture-helper")

        // Bundle.main inside xctest is the test harness, not Tailscreen. The
        // helper-spawn sites (HelperScreenCapture, PickerHelperClient) honour
        // TAILSCREEN_HELPER_EXE as an override; point them at the real binary.
        let binary = try TailscreenE2E.resolveTailscreenBinary()
        setenv("TAILSCREEN_HELPER_EXE", binary.path, 1)
        addTeardownBlock { unsetenv("TAILSCREEN_HELPER_EXE") }

        // Build the picker selection in the TEST process WITHOUT touching
        // SCShareableContent. CGMainDisplayID() is a CoreGraphics call that
        // doesn't register us with replayd, so the capture-helper child's
        // subsequent SCStream still comes up cleanly. The helper resolves
        // the display ID against SCShareableContent on its own side (legal
        // there per CaptureHelperMain.buildFilter).
        let selection = PickerSelection(
            kind: .display,
            displayID: UInt32(CGMainDisplayID()),
            windowID: nil,
            bundleIDs: []
        )
        let filterData = try JSONEncoder().encode(selection)

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
            let host = NSView(frame: win.contentView!.bounds)
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

        // ScreenCaptureKit only delivers a frame when the captured content
        // changes; on a perfectly static display the helper emits its startup
        // keyframe and then nothing, so a viewer that joins after that initial
        // burst can starve (the server's force-keyframe-on-join has no encoder
        // input to act on). Jiggle the cursor a couple of pixels on a timer to
        // keep generating frame deltas until the viewer decodes one. Restores
        // the original position when cancelled.
        let jiggle = Task {
            let origin = CGEvent(source: nil)?.location ?? .zero
            var toggled = false
            while !Task.isCancelled {
                let p = CGPoint(x: origin.x + (toggled ? 6 : 0), y: origin.y)
                CGWarpMouseCursorPosition(p)
                toggled.toggle()
                try? await Task.sleep(for: .milliseconds(200))
            }
            CGWarpMouseCursorPosition(origin)
        }
        addTeardownBlock { jiggle.cancel() }

        // 30 s ceiling: SCStream startup, first keyframe, tsnet propagation,
        // RTP delivery, decode, display-link render. Loose enough to absorb a
        // cold machine without letting a real regression hide.
        await fulfillment(of: [firstFrame], timeout: 30)
        jiggle.cancel()

        await client.disconnect()
        await server.stop()
    }
}
