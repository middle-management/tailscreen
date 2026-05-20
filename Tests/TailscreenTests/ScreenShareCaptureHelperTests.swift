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

        let firstFrame = expectation(description: "viewer decoded a frame")
        firstFrame.assertForOverFulfill = false
        await MainActor.run {
            renderer.onVideoSizeChanged = { size in
                if size.width > 0, size.height > 0 {
                    firstFrame.fulfill()
                }
            }
        }

        try await client.connect(
            to: serverIP,
            port: NetworkConfig.tailscreenPort,
            authKey: envCfg.authKey,
            path: dirs.client,
            controlURL: envCfg.controlURL
        )
        addTeardownBlock { Task { await client.disconnect() } }

        // 30 s ceiling: SCStream startup, first keyframe, tsnet propagation,
        // RTP delivery, decode. Loose enough to absorb a cold machine without
        // letting a real regression hide.
        await fulfillment(of: [firstFrame], timeout: 30)

        await client.disconnect()
        await server.stop()
    }
}
