import XCTest

@testable import Tailscreen

/// Unit tests for the pure viewer-lifecycle decisions extracted from
/// `TailscaleScreenShareServer` — the audio-relay SSRC anti-spoof gate, the
/// idle-sweep staleness math shared by the connected and pending sweeps, the
/// bounded PLI ring, and the per-viewer RTP header rewrite. No tsnet, no
/// helper — same pattern as `AdaptiveBitrateTests`.
final class ViewerLifecycleDecisionTests: XCTestCase {

    // MARK: - audioRelayDecision

    func testValidSenderRelaysToAllOtherViewers() {
        let ssrcs: [String: UInt32] = ["a:1": 111, "b:2": 222, "c:3": 333]
        let (valid, recipients) = TailscaleScreenShareServer.audioRelayDecision(
            viewerAudioSSRCs: ssrcs, sender: "a:1", headerSSRC: 111)
        XCTAssertTrue(valid)
        XCTAssertEqual(recipients.sorted(), ["b:2", "c:3"])
    }

    func testUnregisteredSenderIsRejected() {
        let ssrcs: [String: UInt32] = ["a:1": 111]
        let (valid, recipients) = TailscaleScreenShareServer.audioRelayDecision(
            viewerAudioSSRCs: ssrcs, sender: "mallory:9", headerSSRC: 111)
        XCTAssertFalse(valid)
        XCTAssertTrue(recipients.isEmpty)
    }

    func testSpoofedSSRCFromRegisteredViewerIsRejected() {
        // Registered viewer b stuffs a's SSRC into its RTP header. The
        // source-address keyed check must reject it — this is the anti-spoof
        // property the relay depends on.
        let ssrcs: [String: UInt32] = ["a:1": 111, "b:2": 222]
        let (valid, recipients) = TailscaleScreenShareServer.audioRelayDecision(
            viewerAudioSSRCs: ssrcs, sender: "b:2", headerSSRC: 111)
        XCTAssertFalse(valid)
        XCTAssertTrue(recipients.isEmpty)
    }

    func testSoleViewerIsValidWithNoRecipients() {
        // The sharer still hears the audio (onAudioReceived); there's just
        // nobody to relay to.
        let (valid, recipients) = TailscaleScreenShareServer.audioRelayDecision(
            viewerAudioSSRCs: ["a:1": 111], sender: "a:1", headerSSRC: 111)
        XCTAssertTrue(valid)
        XCTAssertTrue(recipients.isEmpty)
    }

    // MARK: - staleAddrs

    private let s: UInt64 = 1_000_000_000

    func testStaleAddrsDropsOnlyExpired() {
        let lastSeen: [String: UInt64] = [
            "fresh": 100 * s,  // 5 s ago
            "stale": 80 * s,  // 25 s ago
        ]
        let stale = TailscaleScreenShareServer.staleAddrs(
            lastSeenNs: lastSeen, nowNs: 105 * s, timeoutNs: 15 * s)
        XCTAssertEqual(stale, ["stale"])
    }

    func testExactlyAtTimeoutIsNotStale() {
        // The comparison is strictly greater-than: a viewer idle for exactly
        // the timeout survives one more sweep tick.
        let stale = TailscaleScreenShareServer.staleAddrs(
            lastSeenNs: ["v": 0], nowNs: 15 * s, timeoutNs: 15 * s)
        XCTAssertTrue(stale.isEmpty)
    }

    func testEmptyMapYieldsNoStaleAddrs() {
        XCTAssertTrue(
            TailscaleScreenShareServer.staleAddrs(
                lastSeenNs: [:], nowNs: 100 * s, timeoutNs: 15 * s
            ).isEmpty)
    }

    // MARK: - appendingPLI

    func testPLIRingAppendsInOrder() {
        var ring: [UInt64] = []
        for t in 1...5 {
            ring = TailscaleScreenShareServer.appendingPLI(ring, timestampNs: UInt64(t))
        }
        XCTAssertEqual(ring, [1, 2, 3, 4, 5])
    }

    func testPLIRingCapsAt32DroppingOldest() {
        var ring: [UInt64] = []
        for t in 1...40 {
            ring = TailscaleScreenShareServer.appendingPLI(ring, timestampNs: UInt64(t))
        }
        XCTAssertEqual(ring.count, 32)
        XCTAssertEqual(ring.first, 9)  // 1...8 dropped
        XCTAssertEqual(ring.last, 40)
    }

    // MARK: - rewriteRTPHeader

    func testRewriteOverwritesSequenceAndSSRCOnly() {
        // 12-byte RTP header + 4 payload bytes, all distinct so any
        // out-of-place write is visible.
        var packet = Data((0..<16).map { UInt8($0 &+ 0x40) })
        let original = packet
        TailscaleScreenShareServer.rewriteRTPHeader(
            &packet, sequence: 0xABCD, ssrc: 0x0102_0304)

        XCTAssertEqual(packet[2], 0xAB)
        XCTAssertEqual(packet[3], 0xCD)
        XCTAssertEqual(Array(packet[8...11]), [0x01, 0x02, 0x03, 0x04])
        // Everything else — version/flags, payload type, timestamp, payload —
        // is untouched.
        for i in [0, 1, 4, 5, 6, 7, 12, 13, 14, 15] {
            XCTAssertEqual(packet[i], original[i], "byte \(i) should be untouched")
        }
    }

    func testRewrittenPacketDecodesWithNewValues() throws {
        // Build a real packet via the packetizer (ssrc/seq zeroed templates,
        // exactly how `broadcast` uses it), rewrite, and decode it back.
        let packetizer = H264Packetizer()
        let nal = Data([0x65, 0x11, 0x22, 0x33])
        let packets = packetizer.packetize(
            nals: [nal], timestamp: 9000, ssrc: 0, startSequence: 0)
        var packet = try XCTUnwrap(packets.first)

        TailscaleScreenShareServer.rewriteRTPHeader(&packet, sequence: 777, ssrc: 0xDEAD_BEEF)
        let (header, _) = try XCTUnwrap(RTPHeader.decode(from: packet))
        XCTAssertEqual(header.sequenceNumber, 777)
        XCTAssertEqual(header.ssrc, 0xDEAD_BEEF)
        XCTAssertEqual(header.timestamp, 9000)
    }
}
