import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// Pins the two pure decisions behind stream (reliable-transport, spec §2.2)
/// viewers: the synthetic addr a stream viewer's whole roster life keys on
/// (`streamViewerAddr`), and the capability mask that keeps loss recovery off
/// a transport that never loses packets (`streamHelloCaps`, TS-STM-005).
///
/// The addr carries two invariants, and both fail silently when broken. It
/// must reduce through `ipFromAddr` to the connection's peer IP — the
/// admitted-viewer gates compare that reduction with `==`, so a stream
/// viewer whose addr reduces to anything else has its annotations and
/// control requests dropped as "non-admitted" while its video plays fine
/// (the same shape as `PeerAddressParsingTests`' IPv6 bug). And its port
/// position must never parse as a real `ip:port`, because `MediaSockets`
/// checks the stream route FIRST: a synthetic addr that could equal a real
/// UDP key would silently hijack that UDP viewer's media onto a stranger's
/// TCP connection.
final class StreamViewerDecisionTests: XCTestCase {
    private let connA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private let connB = UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!

    // MARK: - streamViewerAddr

    func testIPv4AddrReducesToThePeerIP() {
        let addr = TailscaleScreenShareServer.streamViewerAddr(peerIP: "100.64.0.5", connectionID: connA)
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr(addr), "100.64.0.5",
            "the admitted-viewer gates compare ipFromAddr reductions with ==; a stream addr "
                + "that reduces to anything but the connection's IP drops every annotation and "
                + "control request from an admitted viewer")
    }

    func testIPv6AddrReducesToThePeerIP() {
        // `handleStreamDatagram` reduces the connection's peer address first,
        // so the IP arrives BARE (brackets already stripped) — the guest
        // tunnel's addressing, where stream guests actually live.
        let ip = "fd7a:115c:a1e0:ab12::1"
        let addr = TailscaleScreenShareServer.streamViewerAddr(peerIP: ip, connectionID: connA)
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr(addr), ip,
            "an IPv6 stream addr must re-bracket so ipFromAddr's bracket-first rule "
                + "recovers the full literal — an unbracketed one loses its last hextet "
                + "to the port strip")
    }

    func testTwoConnectionsFromOneIPGetDistinctAddrs() {
        let a = TailscaleScreenShareServer.streamViewerAddr(peerIP: "100.64.0.5", connectionID: connA)
        let b = TailscaleScreenShareServer.streamViewerAddr(peerIP: "100.64.0.5", connectionID: connB)
        XCTAssertNotEqual(
            a, b,
            "TCP peer addresses carry no port, so two viewers on one machine collide on "
                + "bare IP unless the connection disambiguates — one addr keying two viewers "
                + "silently cross-wires their rosters and media")
    }

    func testSameConnectionYieldsTheSameAddr() {
        let a = TailscaleScreenShareServer.streamViewerAddr(peerIP: "100.64.0.5", connectionID: connA)
        let b = TailscaleScreenShareServer.streamViewerAddr(peerIP: "100.64.0.5", connectionID: connA)
        XCTAssertEqual(a, b, "the addr is a stable key — re-derivation must not mint a second viewer")
    }

    func testPortPositionCanNeverBeARealUDPKey() {
        let addr = TailscaleScreenShareServer.streamViewerAddr(peerIP: "100.64.0.5", connectionID: connA)
        let portPart = addr.split(separator: ":").last.map(String.init) ?? ""
        XCTAssertNil(
            UInt16(portPart),
            "the suffix is non-numeric ON PURPOSE: MediaSockets consults the stream route "
                + "before the UDP listeners, so a synthetic addr that could equal a real "
                + "ip:port would hijack that UDP viewer's media")
        XCTAssertTrue(portPart.hasPrefix("tcp-"), "the marker names the transport for log readers")
    }

    func testNilPeerIPStillYieldsAUsableKey() {
        // libtailscale can fail to report a remote address; the viewer still
        // needs a unique roster key (its gates will fail closed on IP checks,
        // which is the right degradation for an unidentifiable peer).
        let addr = TailscaleScreenShareServer.streamViewerAddr(peerIP: nil, connectionID: connA)
        XCTAssertFalse(addr.isEmpty)
        let other = TailscaleScreenShareServer.streamViewerAddr(peerIP: nil, connectionID: connB)
        XCTAssertNotEqual(addr, other)
    }

    // MARK: - streamHelloCaps (TS-STM-005)

    func testLossRecoveryCapsAreMasked() {
        let advertised: ScreenShareCaps = [.nack, .receiverReport, .fec]
        let masked = TailscaleScreenShareServer.streamHelloCaps(advertised)
        XCTAssertEqual(
            masked, [.receiverReport],
            "NACK and FEC recover lost datagrams and the stream loses none — leaving them "
                + "advertised charges the retransmit budget and parity bitrate for nothing")
    }

    func testUnrelatedCapsPassThrough() {
        let advertised: ScreenShareCaps = [.receiverReport, .tenBit]
        XCTAssertEqual(
            TailscaleScreenShareServer.streamHelloCaps(advertised), advertised,
            "receiver reports still carry RTT/jitter/liveness on a stream, and bit depth "
                + "is about the decoder, not the transport — masking either would silently "
                + "degrade a healthy stream viewer")
    }

    func testLegacyEmptyCapsStayEmpty() {
        XCTAssertEqual(TailscaleScreenShareServer.streamHelloCaps([]), [])
    }
}
