import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// The invitee's sequencing for spec §13.3: join only on a click, join the
/// invite's source address, answer on the arrival connection. Inbox
/// arithmetic is `ShareRequestInboxTests`'. `@testable` for the reply seam.
final class IncomingInviteCoordinatorTests: XCTestCase {

    @MainActor
    private func makeCoordinator() -> (
        IncomingInviteCoordinator, replies: () -> [(Bool, UUID)], joins: () -> [String]
    ) {
        let coordinator = IncomingInviteCoordinator()
        var replies: [(Bool, UUID)] = []
        var joins: [String] = []
        coordinator.sendResponseForTesting = { replies.append(($0, $1)) }
        coordinator.onJoin = { ip, _ in joins.append(ip) }
        return (coordinator, { replies }, { joins })
    }

    @MainActor
    func testArrivalListsTheInviteWithoutJoining() {
        let (coordinator, replies, joins) = makeCoordinator()
        var notified: [String] = []
        coordinator.onInviteReceived = { notified.append($0.fromHostname) }

        coordinator.noteInvite(
            from: "studio-imac", sourceAddr: "100.64.0.7:53211", connectionID: UUID())

        XCTAssertEqual(coordinator.invites.map(\.sourceKey), ["100.64.0.7"])
        XCTAssertEqual(notified, ["studio-imac"])
        XCTAssertTrue(joins().isEmpty, "TS-MET-023: an invite never opens a viewer by itself")
        XCTAssertTrue(replies().isEmpty)
    }

    @MainActor
    func testAcceptAnswersOnTheArrivalConnectionAndJoinsTheSourceAddress() {
        let (coordinator, replies, joins) = makeCoordinator()
        let connection = UUID()
        // The payload claims one name; only the transport address is joined.
        coordinator.noteInvite(
            from: "100.64.9.9", sourceAddr: "[fd7a:115c::7]:41000", connectionID: connection)

        coordinator.answer(id: coordinator.invites[0].id, accept: true)

        XCTAssertEqual(replies().map(\.0), [true])
        XCTAssertEqual(replies().map(\.1), [connection])
        XCTAssertEqual(joins(), ["fd7a:115c::7"])
        XCTAssertTrue(coordinator.invites.isEmpty)
    }

    @MainActor
    func testDeclineAnswersButDoesNotJoin() {
        let (coordinator, replies, joins) = makeCoordinator()
        coordinator.noteInvite(from: "a", sourceAddr: "100.64.0.1:1", connectionID: UUID())

        coordinator.answer(id: coordinator.invites[0].id, accept: false)

        XCTAssertEqual(replies().map(\.0), [false])
        XCTAssertTrue(joins().isEmpty)
    }

    @MainActor
    func testInviteWithoutSourceAddressIsDropped() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.noteInvite(from: "nowhere", sourceAddr: nil, connectionID: UUID())
        XCTAssertTrue(
            coordinator.invites.isEmpty, "TS-MET-022: no source address, nothing safe to join")
    }

    @MainActor
    func testRetryFromSameSharerCoalescesAndDoesNotRenotify() {
        let (coordinator, _, _) = makeCoordinator()
        var notified = 0
        coordinator.onInviteReceived = { _ in notified += 1 }

        coordinator.noteInvite(from: "a", sourceAddr: "100.64.0.1:1000", connectionID: UUID())
        let retry = UUID()
        coordinator.noteInvite(from: "a", sourceAddr: "100.64.0.1:2000", connectionID: retry)

        XCTAssertEqual(coordinator.invites.count, 1)
        XCTAssertEqual(coordinator.invites[0].connectionID, retry)
        XCTAssertEqual(notified, 1)
    }

    @MainActor
    func testExpiredInviteIsPrunedOnNextArrival() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.noteInvite(
            from: "old", sourceAddr: "100.64.0.1:1", connectionID: UUID(), nowNs: 1)
        coordinator.noteInvite(
            from: "fresh", sourceAddr: "100.64.0.2:1", connectionID: UUID(),
            nowNs: 2 + IncomingInviteCoordinator.inviteTTLNs)
        XCTAssertEqual(coordinator.invites.map(\.fromHostname), ["fresh"])
    }

    @MainActor
    func testAnsweringTwiceSendsOneReply() {
        let (coordinator, replies, joins) = makeCoordinator()
        coordinator.noteInvite(from: "a", sourceAddr: "100.64.0.1:1", connectionID: UUID())
        let id = coordinator.invites[0].id
        coordinator.answer(id: id, accept: true)
        coordinator.answer(id: id, accept: true)
        XCTAssertEqual(replies().count, 1)
        XCTAssertEqual(joins().count, 1)
    }

    @MainActor
    func testAskToShareCoordinatorOwnsTheInvitesAndClearsThemOnStop() async {
        let owner = SharerAskToShareCoordinator()
        owner.invites.noteInvite(from: "a", sourceAddr: "100.64.0.1:1", connectionID: UUID())
        XCTAssertEqual(owner.invites.invites.count, 1)
        await owner.stopListener()
        XCTAssertTrue(owner.invites.invites.isEmpty)
    }
}
