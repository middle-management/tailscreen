import TailscreenProtocol
import XCTest

@testable import TailscreenViewerTsnet

/// Pins the node-naming contract that decides whether other peers can see this
/// host at all.
///
/// `TailscalePeerDiscovery` admits a peer only if
/// `TailscreenInstance.isTailscreenServerHostname` says its hostname looks like
/// a long-lived instance. That predicate is prefix-based, so the *name* a node
/// registers under silently determines its visibility — get it wrong in either
/// direction and the failure is invisible until someone opens a screen list:
/// a viewer that names itself like a sharer clutters everyone's list with
/// transient nodes, and a sharer that names itself like a viewer can never be
/// picked by anyone.
///
/// Neither failure produces an error anywhere, which is exactly why it's worth
/// a test rather than a comment. Bringing a real node up needs a tailnet
/// (local-only), but the naming decision is pure.
final class NodeIdentityTests: XCTestCase {

    func testViewerOnlyNodeIsHiddenFromDiscovery() {
        let id = TsnetTransport.nodeIdentity(for: .viewerOnly, uniqueSuffix: "0123456789abcdef")
        XCTAssertFalse(
            TailscreenInstance.isTailscreenServerHostname(id.hostName),
            "a viewer-only node must not appear as a connectable screen")
        XCTAssertTrue(id.hostName.hasPrefix(TailscreenInstance.viewerHostnamePrefix))
    }

    func testShareCapableNodeIsDiscoverable() {
        let id = TsnetTransport.nodeIdentity(for: .shareCapable(name: "workstation"), uniqueSuffix: "unused")
        XCTAssertTrue(
            TailscreenInstance.isTailscreenServerHostname(id.hostName),
            "a share-capable node must be discoverable, or nobody can pick it")
        XCTAssertEqual(id.hostName, "\(TailscreenInstance.serverHostnamePrefix)workstation")
    }

    /// Ephemeral nodes vanish from the tailnet the moment they go down. That's
    /// right for a transient viewer and wrong for a host peers may reconnect
    /// to, so the two roles must differ here.
    func testEphemeralityFollowsRole() {
        XCTAssertTrue(TsnetTransport.nodeIdentity(for: .viewerOnly, uniqueSuffix: "x").ephemeral)
        XCTAssertFalse(
            TsnetTransport.nodeIdentity(for: .shareCapable(name: "box"), uniqueSuffix: "x").ephemeral)
    }

    /// Viewer names carry a random suffix so two viewers on one tailnet don't
    /// collide; share-capable names are stable so a peer reconnecting finds the
    /// same host rather than a new one each launch.
    func testViewerNamesAreUniquePerLaunchButSharerNamesAreStable() {
        let a = TsnetTransport.nodeIdentity(for: .viewerOnly, uniqueSuffix: "aaaaaaaaaaaa")
        let b = TsnetTransport.nodeIdentity(for: .viewerOnly, uniqueSuffix: "bbbbbbbbbbbb")
        XCTAssertNotEqual(a.hostName, b.hostName)

        let s1 = TsnetTransport.nodeIdentity(for: .shareCapable(name: "box"), uniqueSuffix: "aaaa")
        let s2 = TsnetTransport.nodeIdentity(for: .shareCapable(name: "box"), uniqueSuffix: "zzzz")
        XCTAssertEqual(s1.hostName, s2.hostName, "a sharer's identity must not change per launch")
    }

    /// The prefixes overlap (`tailscreen-client-` starts with `tailscreen-`),
    /// so the predicate depends on the *exclusion* half as much as the
    /// inclusion half. Assert the relationship directly rather than trusting
    /// the two string constants to stay compatible.
    func testViewerPrefixIsDeliberatelyASubprefixOfTheServerPrefix() {
        XCTAssertTrue(
            TailscreenInstance.viewerHostnamePrefix.hasPrefix(TailscreenInstance.serverHostnamePrefix),
            "the exclusion rule only works because the viewer prefix extends the server one")
        XCTAssertTrue(
            TailscreenInstance.viewerHostnamePrefix.hasPrefix(TailscreenInstance.clientHostnamePrefix))
    }
}
