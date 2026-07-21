import XCTest

@testable import TailscreenProtocol

final class TailscreenInstanceTests: XCTestCase {
    func testServerHostnameMatches() {
        XCTAssertTrue(TailscreenInstance.isTailscreenServerHostname("tailscreen-wisp"))
        XCTAssertTrue(TailscreenInstance.isTailscreenServerHostname("tailscreen-fredriks-macbook-pro-2"))
        XCTAssertTrue(TailscreenInstance.isTailscreenServerHostname("tailscreen-"))
    }

    func testClientHostnameIsExcluded() {
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("tailscreen-client-abc123"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("tailscreen-client-"))
    }

    func testViewerHostnameIsExcluded() {
        // The portable viewer (Apps/linux) registers under viewerHostnamePrefix;
        // it must not appear as a connectable screen in peer discovery.
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("tailscreen-client-viewer-1a2b3c4d"))
        XCTAssertFalse(
            TailscreenInstance.isTailscreenServerHostname(TailscreenInstance.viewerHostnamePrefix + "deadbeef"))
        // The exclusion relies on the viewer prefix being built on the client
        // prefix — lock that invariant so a rename can't silently re-leak it.
        XCTAssertTrue(TailscreenInstance.viewerHostnamePrefix.hasPrefix(TailscreenInstance.clientHostnamePrefix))
    }

    func testUnrelatedHostnameIsRejected() {
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("departmentpi"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("iphone181"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("snow"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname(""))
    }

    func testPrefixIsCaseSensitive() {
        // Tailscale normalizes to lowercase; everything we register is
        // already lowercase. Don't accept variants that could collide
        // with non-Tailscreen nodes the user named themselves.
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("Tailscreen-wisp"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("TAILSCREEN-wisp"))
    }
}
