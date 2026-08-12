import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// The four labels a sharer sees a *person* under — the connected roster, the
/// approval gate, a control request, and the live grant.
///
/// One suite because they are one rule: every one of these names comes from a
/// netmap hostname, every Tailscreen node registers under the `tailscreen-`
/// discovery marker, and none of these surfaces should show it. They also
/// share the fallback — a row must still name something actionable while the
/// StableNodeID/hostname lookup is outstanding, which takes a beat after the
/// connection lands (see `resolveIdentitiesLoop`).
///
/// `@testable` for `ViewerInfo`/`PendingViewerInfo`'s memberwise inits: the
/// server constructs them, the app only ever receives them, so neither carries
/// a public init.
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
        // The one thing worse than a prefixed name is no name: these strings
        // sit in an approval prompt and a grant banner, where the answer is a
        // decision about a machine you must be able to identify.
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
        // A viewer-only node registers under `clientHostnamePrefix`, which is
        // built on the server prefix — the label must not read "client-…".
        let viewer = ViewerInfo(
            id: "100.64.0.9:51000", tailscaleIP: "100.64.0.9",
            hostname: "tailscreen-client-1a2b3c4d", stableID: nil, connectedAt: Date())
        XCTAssertEqual(viewer.displayName, "1a2b3c4d")
    }
}
