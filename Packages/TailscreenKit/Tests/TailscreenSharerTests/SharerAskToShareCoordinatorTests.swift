import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// Pins the ask-to-share sequencing all three hosts now share — the piece
/// protocol.md's pitfall section documents rule by rule, because each rule was
/// once hand-written per host and each has a silent failure mode: an answer
/// that dials back reaches whoever holds the address now; an accept that skips
/// pre-approval parks the person just invited at this machine's own gate; a
/// stale row is a button that does nothing.
///
/// No tsnet node anywhere: the reply send is observed through the
/// coordinator's internal seam (`sendResponseForTesting`) — which is also why
/// this suite, unlike its neighbours, needs `@testable`: the decision
/// *surface* stays public, the seam stays internal. The inbox arithmetic
/// (coalescing key, cap, expiry math) is `ShareRequestInboxTests`' — what is
/// pinned here is the sequencing around it.
final class SharerAskToShareCoordinatorTests: XCTestCase {

    @MainActor
    private func makeCoordinator() -> (
        SharerAskToShareCoordinator, replies: () -> [(Bool, UUID)]
    ) {
        let coordinator = SharerAskToShareCoordinator()
        var replies: [(Bool, UUID)] = []
        coordinator.sendResponseForTesting = { accepted, connectionID in
            replies.append((accepted, connectionID))
        }
        return (coordinator, { replies })
    }

    // MARK: Arrival

    @MainActor
    func testArrivalPublishesTheInbox() async throws {
        let (coordinator, _) = makeCoordinator()
        var published: [[PendingShareRequest]] = []
        var received: [String] = []
        coordinator.onRequestsChanged = { published.append($0) }
        coordinator.onRequestReceived = { received.append($0) }

        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: UUID())

        XCTAssertEqual(received, ["robert-macbook"])
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(coordinator.requests.first?.sourceKey, "100.64.0.7")
    }

    @MainActor
    func testExpiredRowIsPrunedWhenANewAskArrives() async throws {
        let (coordinator, _) = makeCoordinator()
        let second = 1_000_000_000 as UInt64

        coordinator.noteRequest(
            from: "old", sourceAddr: "100.64.0.1:1000", connectionID: UUID(), nowNs: second)
        coordinator.noteRequest(
            from: "fresh", sourceAddr: "100.64.0.2:2000", connectionID: UUID(),
            nowNs: second + SharerAskToShareCoordinator.requestTTLNs + 1)

        // The requester waits 120 s and gives up; a row past that is a Share
        // button answering a connection that has already gone.
        XCTAssertEqual(coordinator.requests.map(\.fromHostname), ["fresh"])
    }

    @MainActor
    func testDroppedFloodArrivalDoesNotRepublish() async throws {
        let (coordinator, _) = makeCoordinator()
        for i in 0..<ShareRequestInbox.maxPending {
            coordinator.noteRequest(
                from: "host-\(i)", sourceAddr: "100.64.1.\(i):40000", connectionID: UUID())
        }
        var publishes = 0
        coordinator.onRequestsChanged = { _ in publishes += 1 }
        coordinator.noteRequest(
            from: "one-too-many", sourceAddr: "100.64.9.9:40000", connectionID: UUID())
        XCTAssertEqual(publishes, 0, "a capped-out arrival changes nothing to publish")
        XCTAssertEqual(coordinator.requests.count, ShareRequestInbox.maxPending)
    }

    // MARK: Answering

    @MainActor
    func testAcceptRepliesOnTheArrivalConnectionThenPreApprovesThenStarts() async throws {
        let (coordinator, replies) = makeCoordinator()
        var order: [String] = []
        coordinator.onPreApproveViewer = { order.append("preapprove:\($0)") }
        coordinator.onStartShare = { order.append("start") }

        let connection = UUID()
        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: connection)
        let request = try XCTUnwrap(coordinator.requests.first)

        coordinator.answer(id: request.id, accept: true)

        XCTAssertTrue(coordinator.requests.isEmpty)
        XCTAssertEqual(replies().count, 1)
        XCTAssertEqual(replies().first?.0, true)
        // ON the connection the ask arrived on — a dial-back would answer
        // whoever currently holds the requester's claimed address.
        XCTAssertEqual(replies().first?.1, connection)
        // Pre-approve strictly before the share flow: the invitee's HELLO can
        // arrive the moment the share is up.
        XCTAssertEqual(order, ["preapprove:100.64.0.7", "start"])
    }

    @MainActor
    func testAcceptAfterARetryRepliesOnTheFreshestConnection() async throws {
        let (coordinator, replies) = makeCoordinator()
        let stale = UUID()
        let fresh = UUID()

        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: stale)
        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53999", connectionID: fresh)
        XCTAssertEqual(coordinator.requests.count, 1, "a retry coalesces, not stacks")

        let request = try XCTUnwrap(coordinator.requests.first)
        coordinator.answer(id: request.id, accept: true)

        // The old connection is most likely why the peer retried; an answer
        // sent down it reaches nobody.
        XCTAssertEqual(replies().map(\.1), [fresh])
    }

    @MainActor
    func testDeclineRepliesAndNeitherPreApprovesNorStarts() async throws {
        let (coordinator, replies) = makeCoordinator()
        coordinator.onPreApproveViewer = { _ in XCTFail("a decline invites nobody") }
        coordinator.onStartShare = { XCTFail("a decline starts nothing") }

        let connection = UUID()
        coordinator.noteRequest(
            from: "studio-imac", sourceAddr: "100.64.0.9:40100", connectionID: connection)
        let request = try XCTUnwrap(coordinator.requests.first)

        coordinator.answer(id: request.id, accept: false)

        XCTAssertTrue(coordinator.requests.isEmpty)
        XCTAssertEqual(replies().first?.0, false)
        XCTAssertEqual(replies().first?.1, connection)
    }

    @MainActor
    func testAcceptWithNoConnectionStillPreApprovesAndStarts() async throws {
        // A legacy transport that never learned the connection: nothing to
        // reply on, but the person still said yes — the share must happen.
        let (coordinator, replies) = makeCoordinator()
        var order: [String] = []
        coordinator.onPreApproveViewer = { order.append("preapprove:\($0)") }
        coordinator.onStartShare = { order.append("start") }

        coordinator.noteRequest(
            from: "legacy", sourceAddr: "100.64.0.4:100", connectionID: nil)
        let request = try XCTUnwrap(coordinator.requests.first)
        coordinator.answer(id: request.id, accept: true)

        XCTAssertTrue(replies().isEmpty)
        XCTAssertEqual(order, ["preapprove:100.64.0.4", "start"])
    }

    @MainActor
    func testAnsweringAnUnknownIdDoesNothing() async throws {
        let (coordinator, replies) = makeCoordinator()
        var publishes = 0
        coordinator.onRequestsChanged = { _ in publishes += 1 }
        coordinator.onStartShare = { XCTFail("nothing was asked") }

        coordinator.answer(id: UUID(), accept: true)

        XCTAssertEqual(publishes, 0)
        XCTAssertTrue(replies().isEmpty)
    }

    // MARK: Clearing

    @MainActor
    func testClearPublishesOnceAndOnlyWhenSomethingWasParked() async throws {
        let (coordinator, _) = makeCoordinator()
        var published: [[PendingShareRequest]] = []
        coordinator.onRequestsChanged = { published.append($0) }

        coordinator.noteRequest(
            from: "a", sourceAddr: "100.64.0.1:1", connectionID: UUID())
        coordinator.clearRequests()
        XCTAssertEqual(published.last, [])
        let count = published.count

        // Empty already — a second clear must not republish (and re-notify).
        coordinator.clearRequests()
        XCTAssertEqual(published.count, count)
    }
}
