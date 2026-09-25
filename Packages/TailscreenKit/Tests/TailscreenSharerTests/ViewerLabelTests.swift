import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// The four labels a sharer sees a person under (roster, approval gate,
/// control request, live grant) all derive from a netmap hostname and must
/// strip the `tailscreen-` discovery marker, with a numeric-IP fallback while
/// the StableNodeID/hostname lookup is outstanding (`resolveIdentitiesLoop`).
///
/// `@testable` since `ViewerInfo`/`PendingViewerInfo` have no public init —
/// the server constructs them, the app only receives them.
final class ViewerLabelTests: XCTestCase {
    func testConnectedViewerLabelDropsTheDiscoveryPrefix() {
        let viewer = ViewerInfo(
            id: "100.64.0.7:49152", tailscaleIP: "100.64.0.7", hostname: "tailscreen-wisp",
            stableID: "n123", connectedAt: Date())
        XCTAssertEqual(viewer.displayName, "wisp")
    }

    func testPendingViewerLabelDropsTheDiscoveryPrefix() {
        let pending = PendingViewerInfo(
            id: "100.64.0.7:49152", tailscaleIP: "100.64.0.7", hostname: "tailscreen-wisp",
            stableID: "n123", arrivedAt: Date())
        XCTAssertEqual(pending.displayName, "wisp")
    }

    func testControlRequestAndGrantLabelsDropTheDiscoveryPrefix() {
        let request = ControlRequestInfo(
            id: UUID(), viewerIP: "100.64.0.7", hostname: "tailscreen-wisp", arrivedAt: Date())
        XCTAssertEqual(request.displayName, "wisp")

        let grant = ControlGrantInfo(
            connectionID: UUID(), viewerIP: "100.64.0.7", hostname: "tailscreen-wisp")
        XCTAssertEqual(grant.displayName, "wisp")
    }

    func testAnUnresolvedViewerIsStillNamedByItsIP() {
        let viewer = ViewerInfo(
            id: "100.64.0.7:49152", tailscaleIP: "100.64.0.7", hostname: nil, stableID: nil,
            connectedAt: Date())
        XCTAssertEqual(viewer.displayName, "100.64.0.7")

        let pending = PendingViewerInfo(
            id: "100.64.0.7:49152", tailscaleIP: "100.64.0.7", hostname: nil, stableID: nil,
            arrivedAt: Date())
        XCTAssertEqual(pending.displayName, "100.64.0.7")

        let request = ControlRequestInfo(
            id: UUID(), viewerIP: "100.64.0.7", hostname: nil, arrivedAt: Date())
        XCTAssertEqual(request.displayName, "100.64.0.7")
    }

    func testAnEphemeralViewerNodeIsNamedByItsSuffixNotItsPrefix() {
        // Viewer-only nodes register under `clientHostnamePrefix`; label must
        // not read "client-…".
        let viewer = ViewerInfo(
            id: "100.64.0.9:51000", tailscaleIP: "100.64.0.9",
            hostname: "tailscreen-client-1a2b3c4d", stableID: nil, connectedAt: Date())
        XCTAssertEqual(viewer.displayName, "1a2b3c4d")
    }
}
