import CoreVideo
import Foundation
import TailscaleKit
import TailscreenAudio
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// End-to-end with TWO viewers on one server over real tsnet (local
/// headscale). Covers two things that a single-viewer test can't:
///
///   1. **Video fan-out** — one `broadcastForTesting` reaches both viewers'
///      decoders (per-viewer SSRC/sequence rewrite, parameter-set prepend on
///      keyframe).
///   2. **Audio relay** — a viewer's outbound audio RTP is both delivered to
///      the sharer locally (`server.onAudioReceived`) and relayed byte-for-byte
///      to the other viewer (`viewer2.onAudioReceived`), gated by the
///      server-assigned SSRC.
///
/// No capture-helper: the server runs with `filterData: nil` and frames are
/// injected via the synthetic broadcast seam, so this is headless and doesn't
/// need Screen Recording permission. Skipped without `TAILSCREEN_TS_AUTHKEY`
/// (run `scripts/e2e-test.sh` for local headscale).
final class ScreenShareFanoutTests: XCTestCase {
    func testTwoViewersDecodeAndRelayAudio() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(
            testCase: self, label: "fanout", names: ["server", "viewer1", "viewer2"])
        let serverDir = try XCTUnwrap(dirs["server"])
        let viewer1Dir = try XCTUnwrap(dirs["viewer1"])
        let viewer2Dir = try XCTUnwrap(dirs["viewer2"])
        let synth = try await TailscreenE2E.encodeSyntheticAUs()

        // Server with no SCStream; seed codec + parameter sets the broadcast
        // path expects (in production these arrive via the capture-helper).
        let server = TailscaleScreenShareServer()

        // Observe the viewer roster; we drive the broadcast only once both
        // viewers have registered so neither misses the keyframe.
        let twoViewers = expectation(description: "server sees two viewers")
        twoViewers.assertForOverFulfill = false
        server.onViewersChanged = { infos in
            if infos.count >= 2 { twoViewers.fulfill() }
        }

        try await server.start(
            hostname: TailscreenE2E.makeHostname("fanout-server"),
            authKey: env.authKey,
            path: serverDir,
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }
        server.injectSyntheticParameters(synth.params)

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        // Bring up two independent viewers (separate tsnet nodes/state dirs).
        let renderer1 = await MainActor.run { MetalViewerRenderer() }
        let renderer2 = await MainActor.run { MetalViewerRenderer() }
        let viewer1 = TailscaleScreenShareClient(renderer: renderer1)
        let viewer2 = TailscaleScreenShareClient(renderer: renderer2)

        // HELLO_ACK (audio SSRC assigned) is the signal a viewer has fully
        // registered with the server.
        let ssrc1 = expectation(description: "viewer1 assigned audio SSRC")
        let ssrc2 = expectation(description: "viewer2 assigned audio SSRC")
        viewer1.onAudioSSRCAssigned = { _ in ssrc1.fulfill() }
        viewer2.onAudioSSRCAssigned = { _ in ssrc2.fulfill() }

        // Both viewers should decode the broadcast frame.
        let decoded1 = expectation(description: "viewer1 decoded a frame")
        let decoded2 = expectation(description: "viewer2 decoded a frame")
        decoded1.assertForOverFulfill = false
        decoded2.assertForOverFulfill = false
        viewer1.onDecodedFrameForTesting = { _ in decoded1.fulfill() }
        viewer2.onDecodedFrameForTesting = { _ in decoded2.fulfill() }

        try await viewer1.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: viewer1Dir, controlURL: env.controlURL)
        addTeardownBlock { Task { await viewer1.disconnect() } }
        try await viewer2.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: viewer2Dir, controlURL: env.controlURL)
        addTeardownBlock { Task { await viewer2.disconnect() } }

        await fulfillment(of: [ssrc1, ssrc2, twoViewers], timeout: 30)

        // ── Video fan-out: broadcast a short GOP; both viewers decode. ──
        for (i, au) in synth.aus.enumerated() {
            server.broadcastForTesting(avccData: au.data, isKeyframe: i == 0 || au.isKey)
            try await Task.sleep(for: .milliseconds(33))
        }
        await fulfillment(of: [decoded1, decoded2], timeout: 10)

        // ── Audio relay: viewer1 sends one audio RTP packet. The server must
        // deliver it locally (onAudioReceived) AND relay it to viewer2. ──
        guard let v1SSRC = viewer1.assignedAudioSSRC else {
            XCTFail("viewer1 never got an audio SSRC")
            return
        }
        // Synthetic AU payload — the relay path forwards bytes verbatim and
        // neither side decodes, so a recognizable marker is enough. (Opus
        // encode/decode itself is covered by VoiceChannelTests.)
        let marker = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let packet = AudioRTPPacketizer(ssrc: v1SSRC).packetize(au: marker)

        let serverGotAudio = expectation(description: "sharer received viewer1 audio")
        serverGotAudio.assertForOverFulfill = false
        let viewer2GotAudio = expectation(description: "viewer2 received relayed audio")
        viewer2GotAudio.assertForOverFulfill = false
        server.onAudioReceived = { data in
            if data == packet { serverGotAudio.fulfill() }
        }
        viewer2.onAudioReceived = { data in
            if data == packet { viewer2GotAudio.fulfill() }
        }

        // Resend a few times — UDP, no retransmit; one lost datagram shouldn't
        // fail the test.
        for _ in 0..<10 {
            viewer1.sendAudioRTP(packet)
            try await Task.sleep(for: .milliseconds(100))
        }
        await fulfillment(of: [serverGotAudio, viewer2GotAudio], timeout: 10)

        await viewer1.disconnect()
        await viewer2.disconnect()
        await server.stop()
    }

    /// System audio (RTP PT 99, reserved SSRC 1) injected via the
    /// `broadcastSystemAudioForTesting` seam reaches BOTH viewers, tagged with
    /// the system-audio payload type so a viewer can tell it apart from voice.
    /// No capture-helper: the AU is a real `OpusVoiceEncoder` output.
    /// Local-only — skipped without `TAILSCREEN_TS_AUTHKEY`.
    func testSystemAudioReachesBothViewers() async throws {
        let env = try TailscreenE2E.loadEnvOrSkip()
        let dirs = try TailscreenE2E.makeStateDirs(
            testCase: self, label: "sysaudio", names: ["server", "viewer1", "viewer2"])
        let serverDir = try XCTUnwrap(dirs["server"])
        let viewer1Dir = try XCTUnwrap(dirs["viewer1"])
        let viewer2Dir = try XCTUnwrap(dirs["viewer2"])

        let server = TailscaleScreenShareServer()
        let twoViewers = expectation(description: "server sees two viewers")
        twoViewers.assertForOverFulfill = false
        server.onViewersChanged = { infos in
            if infos.count >= 2 { twoViewers.fulfill() }
        }
        try await server.start(
            hostname: TailscreenE2E.makeHostname("sysaudio-server"),
            authKey: env.authKey,
            path: serverDir,
            controlURL: env.controlURL,
            filterData: nil
        )
        addTeardownBlock { Task { await server.stop() } }

        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        let renderer1 = await MainActor.run { MetalViewerRenderer() }
        let renderer2 = await MainActor.run { MetalViewerRenderer() }
        let viewer1 = TailscaleScreenShareClient(renderer: renderer1)
        let viewer2 = TailscaleScreenShareClient(renderer: renderer2)

        let ssrc1 = expectation(description: "viewer1 assigned audio SSRC")
        let ssrc2 = expectation(description: "viewer2 assigned audio SSRC")
        viewer1.onAudioSSRCAssigned = { _ in ssrc1.fulfill() }
        viewer2.onAudioSSRCAssigned = { _ in ssrc2.fulfill() }

        let v1Sys = expectation(description: "viewer1 got PT99 system audio")
        v1Sys.assertForOverFulfill = false
        let v2Sys = expectation(description: "viewer2 got PT99 system audio")
        v2Sys.assertForOverFulfill = false
        viewer1.onAudioReceived = { data in
            if RTPHeader.decode(from: data)?.header.payloadType == RTPHeader.systemAudioPayloadType {
                v1Sys.fulfill()
            }
        }
        viewer2.onAudioReceived = { data in
            if RTPHeader.decode(from: data)?.header.payloadType == RTPHeader.systemAudioPayloadType {
                v2Sys.fulfill()
            }
        }

        try await viewer1.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: viewer1Dir, controlURL: env.controlURL)
        addTeardownBlock { Task { await viewer1.disconnect() } }
        try await viewer2.connect(
            to: serverIP, port: NetworkConfig.tailscreenPort,
            authKey: env.authKey, path: viewer2Dir, controlURL: env.controlURL)
        addTeardownBlock { Task { await viewer2.disconnect() } }

        await fulfillment(of: [ssrc1, ssrc2, twoViewers], timeout: 30)

        // A real Opus AU (system-audio / music mode).
        let encoder = try OpusVoiceEncoder(application: .audio)
        var au: Data?
        for _ in 0..<4 {
            if let a = try encoder.encode(pcm: [Float](repeating: 0.2, count: 960)) { au = a }
        }
        let auData = try XCTUnwrap(au)

        // UDP: resend a few times so one dropped datagram doesn't fail the test.
        for _ in 0..<10 {
            server.broadcastSystemAudioForTesting(au: auData)
            try await Task.sleep(for: .milliseconds(100))
        }
        await fulfillment(of: [v1Sys, v2Sys], timeout: 10)

        await viewer1.disconnect()
        await viewer2.disconnect()
        await server.stop()
    }
}
