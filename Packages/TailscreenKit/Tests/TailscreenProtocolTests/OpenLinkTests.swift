import XCTest

@testable import TailscreenProtocol

/// The `.openLink` frame and the sharer's offer queue. The URL shape rules
/// themselves are pinned by the conformance vectors (`json/open-link-*`).
final class OpenLinkTests: XCTestCase {
    func testRoundTrip() {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.openLink(url: "https://example.com/a?b=c#d").encode())
        guard case .openLink(let url)? = parser.next() else {
            return XCTFail("expected .openLink")
        }
        XCTAssertEqual(url, "https://example.com/a?b=c#d")
    }

    func testUnacceptableURLIsDroppedAndParsingContinues() {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.openLink(url: "file:///etc/passwd").encode())
        parser.append(ScreenShareMessage.controlRequest.encode())
        guard case .controlRequest? = parser.next() else {
            return XCTFail("a rejected link must not disturb the framing")
        }
        XCTAssertNil(parser.next())
    }

    func testEncodesSlashesUnescaped() {
        let frame = ScreenShareMessage.openLink(url: "https://a.example/").encode()
        let payload = String(decoding: frame.dropFirst(ScreenShareMessage.headerSize), as: UTF8.self)
        XCTAssertEqual(payload, #"{"url":"https://a.example/"}"#)
    }

    func testDisplayHostIsTheAuthorityOnly() {
        let offer = LinkOfferInfo(
            connectionID: UUID(), viewerIP: "100.64.0.2", hostname: nil,
            url: "https://docs.example:8443/path?q=1", arrivedAt: Date())
        XCTAssertEqual(offer.displayHost, "docs.example:8443")
        XCTAssertEqual(offer.displayName, "100.64.0.2")
    }

    func testQueueKeepsOneOfferPerConnection() {
        var queue = LinkOfferQueue()
        let conn = UUID()
        queue.add(offer(conn, "https://a.example/"))
        queue.add(offer(conn, "https://b.example/"))
        XCTAssertEqual(queue.offers.map(\.url), ["https://b.example/"])
    }

    func testQueueEvictsOldestPastCapacity() {
        var queue = LinkOfferQueue()
        let urls = (0...LinkOfferQueue.capacity).map { "https://\($0).example/" }
        for url in urls { queue.add(offer(UUID(), url)) }
        XCTAssertEqual(queue.offers.count, LinkOfferQueue.capacity)
        XCTAssertEqual(queue.offers.map(\.url), Array(urls.dropFirst()))
    }

    func testTakeRemovesOnlyThatOffer() {
        var queue = LinkOfferQueue()
        let first = offer(UUID(), "https://a.example/")
        queue.add(first)
        queue.add(offer(UUID(), "https://b.example/"))
        XCTAssertEqual(queue.take(id: first.id)?.url, "https://a.example/")
        XCTAssertNil(queue.take(id: first.id))
        XCTAssertEqual(queue.offers.count, 1)
    }

    func testClosingAConnectionDropsItsOffers() {
        var queue = LinkOfferQueue()
        let conn = UUID()
        queue.add(offer(conn, "https://a.example/"))
        queue.add(offer(UUID(), "https://b.example/"))
        XCTAssertTrue(queue.removeAll(connectionID: conn))
        XCTAssertFalse(queue.removeAll(connectionID: conn))
        XCTAssertEqual(queue.offers.map(\.url), ["https://b.example/"])
    }

    func testLinkNoticeOffersNoButtons() {
        // An Open button on a banner would open a URL the banner may have
        // truncated — the choice is made in-app (TS-LNK-010).
        XCTAssertTrue(SharerNoticeKind.linkOffered.actions.isEmpty)
        XCTAssertFalse(SharerNoticeKind.linkOffered.blocksSomeone)
    }

    private func offer(_ conn: UUID, _ url: String) -> LinkOfferInfo {
        LinkOfferInfo(connectionID: conn, viewerIP: "100.64.0.2", hostname: nil, url: url, arrivedAt: Date())
    }
}
