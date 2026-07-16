import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

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
