import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// Pins `TailscaleScreenShareServer.ipFromAddr`, the one place a peer
/// address becomes the IP the admission gates compare on.
///
/// Two producers feed it and disagree about format: a viewer's UDP source
/// is `ip:port`, while the TCP control channel's peer address comes back
/// bracketed with no port for IPv6 (`[fd7a::1]` vs `[fd7a::1]:33509`) — both
/// must reduce to one string or `isAdmittedViewerIP` never matches. A prior
/// implementation split on the last colon, silently mangling bracketed
/// portless IPv6 (invisible on IPv4-only tailnets, but broke every
/// remote-control request and annotation on the guest tunnel and any
/// IPv6-only tailnet). The gate is an exact `==`, so both forms of each
/// family are asserted against each other, not just against a literal.
final class PeerAddressParsingTests: XCTestCase {
    // MARK: - The four shapes that reach it

    func testStripsPortFromBracketedIPv6() {
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]:33509"),
            "fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d")
    }

    /// `tailscale_getremoteaddr` returns exactly this for an IPv6 TCP peer.
    func testUnwrapsBracketedIPv6WithNoPort() {
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]"),
            "fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d")
    }

    func testStripsPortFromIPv4() {
        XCTAssertEqual(TailscaleScreenShareServer.ipFromAddr("100.64.0.1:51820"), "100.64.0.1")
    }

    func testLeavesBareIPv4Alone() {
        XCTAssertEqual(TailscaleScreenShareServer.ipFromAddr("100.64.0.1"), "100.64.0.1")
    }

    // MARK: - The property the admission gate actually depends on

    /// This equality is the whole contract `isAdmittedViewerIP` depends on.
    func testUDPKeyAndTCPPeerReduceToTheSameIPv6() {
        let udpKey = "[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]:33509"
        let tcpPeer = "[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]"
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr(udpKey),
            TailscaleScreenShareServer.ipFromAddr(tcpPeer),
            "an admitted viewer's UDP key and its TCP control-channel address must reduce "
                + "to one IP, or every control request and annotation is dropped as non-admitted")
    }

    func testUDPKeyAndTCPPeerReduceToTheSameIPv4() {
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr("100.64.0.1:51820"),
            TailscaleScreenShareServer.ipFromAddr("100.64.0.1"))
    }

    /// The old implementation truncated the last hextet, collapsing every
    /// address in a `/112` onto one string.
    func testDistinctIPv6PeersDoNotCollide() {
        XCTAssertNotEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]"),
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:0001]"))
    }

    // MARK: - Degenerate input

    /// An empty or malformed address collapsing onto `""` would match any
    /// viewer key that also reduced to `""`.
    func testMalformedInputDoesNotMatchARealPeer() {
        let real = TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]")
        for junk in ["", "[", "]", "[]", ":", "unknown"] {
            XCTAssertNotEqual(
                TailscaleScreenShareServer.ipFromAddr(junk), real,
                "malformed address \(junk.debugDescription) must not reduce onto a real peer's IP")
        }
    }

    func testUnterminatedBracketDoesNotMatchTheTerminatedForm() {
        XCTAssertNotEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d"),
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]"))
    }
}
