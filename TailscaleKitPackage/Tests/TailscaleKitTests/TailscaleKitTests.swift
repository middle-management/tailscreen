import XCTest
@testable import TailscaleKit

final class TailscaleKitTests: XCTestCase {
    func testConfigurationInitialization() {
        let config = Configuration(
            hostName: "test-node",
            path: "/tmp/test",
            authKey: "test-key",
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        XCTAssertEqual(config.hostName, "test-node")
        XCTAssertEqual(config.path, "/tmp/test")
        XCTAssertEqual(config.authKey, "test-key")
        XCTAssertEqual(config.controlURL, kDefaultControlURL)
        XCTAssertTrue(config.ephemeral)
    }

    func testNetProtocolValues() {
        XCTAssertEqual(NetProtocol.tcp.rawValue, "tcp")
        XCTAssertEqual(NetProtocol.udp.rawValue, "udp")
    }

    // Note: Full integration tests require a Tailscale auth key
    // and would create actual network connections. Those should be
    // run separately in an integration test suite.
}
