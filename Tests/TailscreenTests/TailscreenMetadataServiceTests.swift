import XCTest

@testable import Tailscreen

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
}
