import XCTest

@testable import Tailscreen

final class TailscalePeerDiscoveryTests: XCTestCase {
    func testPreferIPv4PicksIPv4FromMixedList() {
        let pick = TailscalePeerDiscovery.preferIPv4(["fd7a:115c:a1e0::1", "100.64.0.1"])
        XCTAssertEqual(pick, "100.64.0.1")
    }

    func testPreferIPv4PrefersFirstIPv4WhenMultiple() {
        let pick = TailscalePeerDiscovery.preferIPv4(["100.64.0.1", "100.64.0.2"])
        XCTAssertEqual(pick, "100.64.0.1")
    }

    func testPreferIPv4FallsBackToIPv6IfOnly() {
        let pick = TailscalePeerDiscovery.preferIPv4(["fd7a:115c:a1e0::1"])
        XCTAssertEqual(pick, "fd7a:115c:a1e0::1")
    }

    func testPreferIPv4EmptyListYieldsEmptyString() {
        XCTAssertEqual(TailscalePeerDiscovery.preferIPv4([]), "")
    }
}
