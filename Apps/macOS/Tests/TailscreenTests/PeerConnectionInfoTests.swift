import XCTest

@testable import Tailscreen

/// Pins the peer-detail pane's pure connection decisions: which Tailscale
/// path a peer is on (`PeerRoute`) and which quality tier its measured
/// latency falls in (`ConnectionQualityTier`). Both were extracted from
/// `PeerDetailView`'s private computed properties so their boundaries
/// can't regress silently.
final class PeerConnectionInfoTests: XCTestCase {

    // MARK: - Route classification

    func testDirectEndpointWinsOverRelay() {
        // tsnet reports both fields while a relayed path upgrades to
        // direct; a populated curAddr is the authoritative "direct" signal.
        XCTAssertEqual(
            PeerRoute.from(curAddr: "100.64.0.2:41641", relay: "fra"), .direct)
    }

    func testRelayWhenNoDirectEndpoint() {
        XCTAssertEqual(
            PeerRoute.from(curAddr: nil, relay: "fra"), .relay(region: "fra"))
    }

    func testEmptyStringsCountAsAbsent() {
        // LocalAPI reports "" rather than omitting the key before a path
        // exists — treating "" as present would render an empty
        // "DERP ()" label or a bogus "Direct".
        XCTAssertEqual(PeerRoute.from(curAddr: "", relay: "fra"), .relay(region: "fra"))
        XCTAssertEqual(PeerRoute.from(curAddr: "", relay: ""), .unknown)
        XCTAssertEqual(PeerRoute.from(curAddr: nil, relay: ""), .unknown)
    }

    func testUnknownWhenNeitherFieldPresent() {
        XCTAssertEqual(PeerRoute.from(curAddr: nil, relay: nil), .unknown)
    }

    // MARK: - Latency tiers

    func testLatencyTierBoundaries() {
        // Boundaries are exclusive upper bounds: the threshold value
        // itself belongs to the *next* tier down.
        XCTAssertEqual(ConnectionQualityTier.forLatency(ms: 0), .good)
        XCTAssertEqual(ConnectionQualityTier.forLatency(ms: 59), .good)
        XCTAssertEqual(ConnectionQualityTier.forLatency(ms: 60), .fair)
        XCTAssertEqual(ConnectionQualityTier.forLatency(ms: 149), .fair)
        XCTAssertEqual(ConnectionQualityTier.forLatency(ms: 150), .poor)
        XCTAssertEqual(ConnectionQualityTier.forLatency(ms: 5_000), .poor)
    }

    func testTierBoundariesMatchNamedConstants() {
        // The named constants are the contract the doc comment describes;
        // keep the literals above honest if someone retunes them.
        XCTAssertEqual(
            ConnectionQualityTier.forLatency(ms: ConnectionQualityTier.goodBelowMs - 1), .good)
        XCTAssertEqual(
            ConnectionQualityTier.forLatency(ms: ConnectionQualityTier.goodBelowMs), .fair)
        XCTAssertEqual(
            ConnectionQualityTier.forLatency(ms: ConnectionQualityTier.fairBelowMs - 1), .fair)
        XCTAssertEqual(
            ConnectionQualityTier.forLatency(ms: ConnectionQualityTier.fairBelowMs), .poor)
        XCTAssertLessThan(
            ConnectionQualityTier.goodBelowMs, ConnectionQualityTier.fairBelowMs,
            "tier bounds must stay ordered or the middle tier vanishes")
    }
}
