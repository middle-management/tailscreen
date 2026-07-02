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

    // The display hostname must be identical no matter which source
    // (backendStatus seed or IPN watcher) produced the row — differing
    // spellings of the same node made the open menu's rows flip text.
    func testDisplayHostnameUsesFirstDNSLabel() {
        XCTAssertEqual(
            TailscalePeerDiscovery.displayHostname(
                dnsName: "tailscreen-fredriks-macbook-pro-2.tail1234.ts.net.",
                fallback: "tailscreen-Fredrik's MacBook Pro (2)"),
            "tailscreen-fredriks-macbook-pro-2")
    }

    func testDisplayHostnameFallsBackWhenDNSNameEmpty() {
        XCTAssertEqual(
            TailscalePeerDiscovery.displayHostname(dnsName: "", fallback: "tailscreen-wisp-1"),
            "tailscreen-wisp-1")
    }

    // The seed (PeerStatus.ID, string StableNodeID) and the watcher
    // (netmap Node.ID, numeric) report different identifiers for the
    // same node — the merge must key on something both sides share, or
    // every peer renders twice.
    func testMergeKeyCollidesAcrossSourceSpellings() {
        let fromSeed = TailscalePeerDiscovery.mergeKey(
            dnsName: "tailscreen-wisp-2.tail1234.ts.net.", fallbackID: "nAbCd1234")
        let fromWatcher = TailscalePeerDiscovery.mergeKey(
            dnsName: "Tailscreen-Wisp-2.tail1234.ts.net", fallbackID: "84921")
        XCTAssertEqual(fromSeed, fromWatcher)
        XCTAssertEqual(fromSeed, "tailscreen-wisp-2.tail1234.ts.net")
    }

    func testMergeKeyFallsBackToIDWhenDNSNameEmpty() {
        XCTAssertEqual(TailscalePeerDiscovery.mergeKey(dnsName: "", fallbackID: "n123"), "n123")
    }
}
