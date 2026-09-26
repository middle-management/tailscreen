import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol

/// The wire rules themselves are pinned portably (`OpenLinkTests`); these pin
/// what the mac app layers on top: trimming, and the last check before
/// `NSWorkspace.open`.
final class OpenLinkEntryTests: XCTestCase {
    func testSendableTrimsSurroundingWhitespaceOnly() {
        XCTAssertEqual(
            OpenLinkEntry.sendable("  https://example.com/a?b=c \n"), "https://example.com/a?b=c")
        XCTAssertNil(OpenLinkEntry.sendable("https://example.com/a b"), "inner space is rejected, not repaired")
        XCTAssertNil(OpenLinkEntry.sendable("   "))
    }

    func testSendableRejectsWhatTheSharerWouldDrop() {
        XCTAssertNil(OpenLinkEntry.sendable("example.com"))
        XCTAssertNil(OpenLinkEntry.sendable("file:///etc/passwd"))
        XCTAssertNil(OpenLinkEntry.sendable("javascript:alert(1)"))
        XCTAssertNil(OpenLinkEntry.sendable("https://trusted.example@evil.example/"))
    }

    func testOpenableURLAllowsOnlyHTTPAndHTTPS() {
        XCTAssertEqual(OpenLinkEntry.openableURL("HTTPS://example.com/x")?.host, "example.com")
        XCTAssertNotNil(OpenLinkEntry.openableURL("http://example.com:8080/"))
        XCTAssertNil(OpenLinkEntry.openableURL("ftp://example.com/"))
        XCTAssertNil(OpenLinkEntry.openableURL("tailscreen:abc"))
        XCTAssertNil(OpenLinkEntry.openableURL("https://a@b.example/"))
    }

    /// Keyed per offer: a viewer's newer link replaces its older one on the
    /// server, and that must withdraw the old banner and post a new one.
    func testLinkNoticesAreKeyedByOfferID() {
        let connection = UUID()
        let first = LinkOfferInfo(
            connectionID: connection, viewerIP: "100.64.0.7", hostname: nil,
            url: "https://a.example/", arrivedAt: Date())
        let replacement = LinkOfferInfo(
            connectionID: connection, viewerIP: "100.64.0.7", hostname: nil,
            url: "https://b.example/", arrivedAt: Date())
        let notified: Set<String> = [first.id.uuidString]
        let candidates = AppState.noticeCandidates([replacement])
        XCTAssertEqual(candidates.map(\.label), ["100.64.0.7"])
        XCTAssertEqual(
            SharerNoticeDecision.noticesToWithdraw(candidates: candidates, alreadyNotified: notified),
            [first.id.uuidString])
        XCTAssertEqual(
            SharerNoticeDecision.noticesToPost(
                kind: .linkOffered, candidates: candidates, alreadyNotified: notified
            ).post.map(\.identity),
            [replacement.id.uuidString])
    }
}
