import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

/// Pins `TailscaleScreenShareServer.ipFromAddr`, the one place a peer address
/// becomes the IP the admission gates compare on.
///
/// Two producers feed it and they disagree about format. A viewer's UDP source
/// arrives as `ip:port` (that is the `viewers` dictionary key). The TCP control
/// channel's peer address comes back through `tailscale_getremoteaddr`, whose Go
/// side runs it through `extractIP` — a regex that strips the port and, for
/// IPv6, **keeps the brackets**. So the same peer is `[fd7a::1]:33509` on one
/// path and `[fd7a::1]` on the other, and both have to reduce to one string or
/// `isAdmittedViewerIP` never matches.
///
/// It is a suite rather than a review note because the failure is silent and
/// selective. The old implementation split on the last colon and unwrapped the
/// brackets only when the result still ended in `]`. A bracketed, portless IPv6
/// literal therefore lost its final hextet AND kept its opening bracket — while
/// IPv4 came out right, because `extractIP` emits it bare and the early return
/// fires. Tailnets hand out `100.64.0.0/10`, so everyday use took the working
/// path and the bug only surfaced where addressing is IPv6-only: the guest
/// (share-by-token) tunnel, and any tailnet running without IPv4. There, every
/// remote-control request and every annotation from an admitted viewer was
/// dropped as "non-admitted", with the sharer showing a healthy share and the
/// viewer's request simply never arriving.
///
/// The gate is an exact `==`, so a near-miss is a total miss. Both forms of
/// each family are asserted against each other rather than only against a
/// literal: an implementation that mangled both consistently would satisfy
/// per-case expectations and still be wrong at the only call that matters.
final class PeerAddressParsingTests: XCTestCase {
    // MARK: - The four shapes that reach it

    func testStripsPortFromBracketedIPv6() {
        XCTAssertEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]:33509"),
            "fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d")
    }

    /// The regression. `tailscale_getremoteaddr` returns exactly this for an
    /// IPv6 TCP peer: brackets kept, no port. Splitting on the last colon eats
    /// `714d` and leaves the `[`.
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

    /// `isAdmittedViewerIP` compares the reduction of a `viewers` key against
    /// the reduction of a TCP peer address. Neither literal above matters on
    /// its own; this equality is the whole contract.
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

    /// Two peers differing only in the last hextet must stay apart. The old
    /// implementation truncated exactly that group, so on the portless path
    /// every address in a `/112` collapsed onto one string — a viewer admitted
    /// on one address would have gated in traffic from its neighbour.
    func testDistinctIPv6PeersDoNotCollide() {
        XCTAssertNotEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]"),
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:0001]"))
    }

    // MARK: - Degenerate input

    /// Whatever these reduce to, it must not accidentally equal a real peer's
    /// reduction — an empty or malformed address that collapsed onto `""` would
    /// match any viewer key that also reduced to `""`.
    func testMalformedInputDoesNotMatchARealPeer() {
        let real = TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]")
        for junk in ["", "[", "]", "[]", ":", "unknown"] {
            XCTAssertNotEqual(
                TailscaleScreenShareServer.ipFromAddr(junk), real,
                "malformed address \(junk.debugDescription) must not reduce onto a real peer's IP")
        }
    }

    /// An unterminated bracket has no well-formed IP in it; the only
    /// requirement is that it does not throw away input in a way that makes it
    /// collide with the terminated form.
    func testUnterminatedBracketDoesNotMatchTheTerminatedForm() {
        XCTAssertNotEqual(
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d"),
            TailscaleScreenShareServer.ipFromAddr("[fd7a:115c:a1e0:b5f0:9f0f:250c:9e35:714d]"))
    }
}
