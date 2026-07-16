import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

final class TailscreenMetadataServiceTests: XCTestCase {
    @MainActor
    func testHandleRequestToShareCoalescesRepeatsFromSameHost() {
        let svc = TailscreenMetadataService()

        svc.handleRequestToShare(from: "wisp-1")
        svc.handleRequestToShare(from: "wisp-1")
        svc.handleRequestToShare(from: "wisp-1")

        XCTAssertEqual(svc.pendingRequests.count, 1)
        XCTAssertEqual(svc.pendingRequests.first?.fromHostname, "wisp-1")
    }

    @MainActor
    func testHandleRequestToShareKeepsDistinctHosts() {
        let svc = TailscreenMetadataService()

        svc.handleRequestToShare(from: "wisp-1")
        svc.handleRequestToShare(from: "wisp-2")
        svc.handleRequestToShare(from: "wisp-1")

        XCTAssertEqual(svc.pendingRequests.count, 2)
        XCTAssertEqual(svc.pendingRequests.map(\.fromHostname).sorted(), ["wisp-1", "wisp-2"])
    }

    @MainActor
    func testHandleRequestToShareRefreshesIdOnCoalesce() {
        let svc = TailscreenMetadataService()
        svc.handleRequestToShare(from: "wisp-1")
        let firstID = svc.pendingRequests.first?.id

        svc.handleRequestToShare(from: "wisp-1")
        let secondID = svc.pendingRequests.first?.id

        // Same row identity preserved across coalesce so SwiftUI ForEach
        // doesn't remount the banner.
        XCTAssertEqual(firstID, secondID)
    }

    @MainActor
    func testHandleRequestToShareCoalesceTakesFreshestConnectionID() {
        // A retry arrives on a new TCP connection; the response must ride
        // the freshest one (the old connection is likely dead). A retry
        // without a connection ID keeps the previous one.
        let svc = TailscreenMetadataService()
        let firstConn = UUID()
        let secondConn = UUID()

        svc.handleRequestToShare(from: "wisp-1", connectionID: firstConn)
        XCTAssertEqual(svc.pendingRequests.first?.connectionID, firstConn)

        svc.handleRequestToShare(from: "wisp-1", connectionID: secondConn)
        XCTAssertEqual(svc.pendingRequests.count, 1)
        XCTAssertEqual(svc.pendingRequests.first?.connectionID, secondConn)

        svc.handleRequestToShare(from: "wisp-1")
        XCTAssertEqual(svc.pendingRequests.first?.connectionID, secondConn)
    }

    @MainActor
    func testCoalescesOnSourceIPDespiteVaryingHostname() {
        // Retries dial a fresh source port, and an attacker can vary the
        // wire-claimed hostname — but same source IP must coalesce onto one
        // row (the spoof-resistant key).
        let svc = TailscreenMetadataService()
        svc.handleRequestToShare(from: "claimed-a", sourceAddr: "100.64.0.5:41000")
        svc.handleRequestToShare(from: "claimed-b", sourceAddr: "100.64.0.5:41001")
        svc.handleRequestToShare(from: "claimed-c", sourceAddr: "100.64.0.5:41002")
        XCTAssertEqual(svc.pendingRequests.count, 1)

        // A genuinely different source IP is a distinct requester.
        svc.handleRequestToShare(from: "claimed-a", sourceAddr: "100.64.0.9:50000")
        XCTAssertEqual(svc.pendingRequests.count, 2)
    }

    @MainActor
    func testPendingRequestsAreCapped() {
        let svc = TailscreenMetadataService()
        let cap = TailscreenMetadataService.maxPendingRequests
        for i in 0..<(cap + 5) {
            svc.handleRequestToShare(from: "host-\(i)", sourceAddr: "100.64.1.\(i):40000")
        }
        XCTAssertEqual(svc.pendingRequests.count, cap)
    }

    func testSourceKeyStripsPortAndBrackets() {
        XCTAssertEqual(TailscreenMetadataService.sourceKey(from: "100.64.0.5:41000"), "100.64.0.5")
        XCTAssertEqual(TailscreenMetadataService.sourceKey(from: "[fd7a::1]:54321"), "fd7a::1")
    }
}
