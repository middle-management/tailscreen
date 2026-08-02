import XCTest

@testable import TailscreenProtocol

/// The sharer's incoming "please share" inbox: coalescing, the cap, and expiry.
///
/// Every case here is an adversarial one, because the honest path — one peer
/// asks once — works under any implementation. What does not work under any
/// implementation is a peer that gets to choose its own coalescing key, and
/// that is what the wire payload's hostname is.
final class ShareRequestInboxTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    // MARK: Coalescing

    func testRetryFromSamePeerReplacesTheRowRatherThanAddingOne() {
        var inbox = ShareRequestInbox()
        let first = UUID()
        let second = UUID()

        inbox.record(
            fromHostname: "robert-mac", sourceAddr: "100.64.0.9:41000",
            connectionID: first, nowNs: 0)
        // A retry dials a FRESH ephemeral port. If the port participated in
        // the key this would look like a second peer.
        inbox.record(
            fromHostname: "robert-mac", sourceAddr: "100.64.0.9:41001",
            connectionID: second, nowNs: 5 * self.second)

        XCTAssertEqual(inbox.requests.count, 1)
        // The row keeps its identity so it does not flicker out of the
        // sharer's window and back in…
        XCTAssertEqual(inbox.requests[0].id, inbox.requests[0].id)
        // …but takes the NEW connection: the old one is most likely why the
        // peer retried, and an answer sent down it reaches nobody.
        XCTAssertEqual(inbox.requests[0].connectionID, second)
        XCTAssertEqual(inbox.requests[0].receivedAtNs, 5 * self.second)
    }

    func testRetryKeepsTheOriginalRowIdentity() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.9:1", connectionID: nil, nowNs: 0)
        let originalID = inbox.requests[0].id
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.9:2", connectionID: nil, nowNs: second)
        XCTAssertEqual(inbox.requests[0].id, originalID)
    }

    func testARenamingPeerStillCoalescesOntoOneRow() {
        var inbox = ShareRequestInbox()
        // The hostname is chosen by the requester. Keying on it is the bug
        // this test exists to prevent: one machine could stack sixteen rows
        // and pin sixteen connections just by varying a string.
        for i in 0..<20 {
            inbox.record(
                fromHostname: "attacker-\(i)", sourceAddr: "100.64.0.9:\(4000 + i)",
                connectionID: UUID(), nowNs: UInt64(i) * second)
        }
        XCTAssertEqual(inbox.requests.count, 1)
        // The row shows the LATEST name it claimed — display follows the
        // freshest request even though identity does not.
        XCTAssertEqual(inbox.requests[0].fromHostname, "attacker-19")
    }

    func testDistinctPeersEachGetARow() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.9:1", connectionID: nil, nowNs: 0)
        inbox.record(
            fromHostname: "b", sourceAddr: "100.64.0.10:1", connectionID: nil, nowNs: 0)
        XCTAssertEqual(inbox.requests.count, 2)
    }

    func testRetryReordersToNewestLast() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.9:1", connectionID: nil, nowNs: 0)
        inbox.record(
            fromHostname: "b", sourceAddr: "100.64.0.10:1", connectionID: nil, nowNs: second)
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.9:2", connectionID: nil,
            nowNs: 2 * second)
        XCTAssertEqual(inbox.requests.map(\.fromHostname), ["b", "a"])
    }

    func testMissingAddressFallsBackToTheHostnameKey() {
        var inbox = ShareRequestInbox()
        // A legacy transport that never reported the peer address. Coalescing
        // on the claimed hostname is worse than coalescing on the IP, but it
        // still beats a row per retry.
        inbox.record(fromHostname: "a", sourceAddr: nil, connectionID: nil, nowNs: 0)
        inbox.record(fromHostname: "a", sourceAddr: nil, connectionID: nil, nowNs: second)
        inbox.record(fromHostname: "b", sourceAddr: nil, connectionID: nil, nowNs: second)
        XCTAssertEqual(inbox.requests.count, 2)
    }

    // MARK: The cap

    func testDistinctRequestersAreCappedAndTheCapIsReported() {
        var inbox = ShareRequestInbox()
        for i in 0..<ShareRequestInbox.maxPending {
            XCTAssertTrue(
                inbox.record(
                    fromHostname: "peer-\(i)", sourceAddr: "100.64.1.\(i):1",
                    connectionID: nil, nowNs: 0),
                "the \(i)th distinct requester should still fit")
        }
        XCTAssertFalse(
            inbox.record(
                fromHostname: "one-too-many", sourceAddr: "100.64.9.9:1",
                connectionID: nil, nowNs: 0),
            "past the cap a new distinct requester is dropped, and says so")
        XCTAssertEqual(inbox.requests.count, ShareRequestInbox.maxPending)
    }

    func testAFullInboxStillAcceptsRetriesFromPeersAlreadyInIt() {
        var inbox = ShareRequestInbox()
        for i in 0..<ShareRequestInbox.maxPending {
            inbox.record(
                fromHostname: "peer-\(i)", sourceAddr: "100.64.1.\(i):1",
                connectionID: nil, nowNs: 0)
        }
        let fresh = UUID()
        // Otherwise a flood that fills the inbox would freeze everyone in it:
        // the sharer answers a row whose connection died, and the peer they
        // meant to help never hears back.
        XCTAssertTrue(
            inbox.record(
                fromHostname: "peer-0", sourceAddr: "100.64.1.0:2",
                connectionID: fresh, nowNs: second))
        XCTAssertEqual(inbox.requests.count, ShareRequestInbox.maxPending)
        XCTAssertEqual(inbox.requests.last?.connectionID, fresh)
    }

    // MARK: Removal and expiry

    func testRemoveReturnsTheRowSoTheAnswerCanBeAddressed() {
        var inbox = ShareRequestInbox()
        let connection = UUID()
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.9:1", connectionID: connection,
            nowNs: 0)
        let id = inbox.requests[0].id
        let removed = inbox.remove(id: id)
        XCTAssertEqual(removed?.connectionID, connection)
        XCTAssertTrue(inbox.requests.isEmpty)
        XCTAssertNil(inbox.remove(id: id), "removing twice is not an error, just nothing")
    }

    func testExpiryDropsOnlyRowsPastTheDeadline() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "old", sourceAddr: "100.64.0.1:1", connectionID: nil, nowNs: 0)
        inbox.record(
            fromHostname: "new", sourceAddr: "100.64.0.2:1", connectionID: nil,
            nowNs: 100 * second)

        XCTAssertTrue(inbox.pruneExpired(nowNs: 130 * second, ttlNs: 120 * second))
        XCTAssertEqual(inbox.requests.map(\.fromHostname), ["new"])
        XCTAssertFalse(
            inbox.pruneExpired(nowNs: 130 * second, ttlNs: 120 * second),
            "a prune that drops nothing reports no change, so hosts can skip a republish")
    }

    func testExpiryIsExclusiveAtExactlyTheDeadline() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.1:1", connectionID: nil, nowNs: 0)
        XCTAssertFalse(inbox.pruneExpired(nowNs: 120 * second, ttlNs: 120 * second))
        XCTAssertEqual(inbox.requests.count, 1)
        XCTAssertTrue(inbox.pruneExpired(nowNs: 120 * second + 1, ttlNs: 120 * second))
    }

    func testExpiryIgnoresAClockThatWentBackwards() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "a", sourceAddr: "100.64.0.1:1", connectionID: nil,
            nowNs: 100 * second)
        // `nowNs - receivedAtNs` on unsigned integers would wrap to an
        // enormous age and expire everything. Nothing should be dropped.
        XCTAssertFalse(inbox.pruneExpired(nowNs: 10 * second, ttlNs: 120 * second))
        XCTAssertEqual(inbox.requests.count, 1)
    }

    // MARK: The key itself

    func testSourceKeyStripsPortsAndIPv6Brackets() {
        XCTAssertEqual(ShareRequestInbox.sourceKey(from: "100.64.0.9:41000"), "100.64.0.9")
        // Split on the LAST colon, or every IPv6 address would lose most of
        // itself and two different peers could collapse onto one row.
        XCTAssertEqual(
            ShareRequestInbox.sourceKey(from: "[fd7a:115c:a1e0::1]:41000"),
            "fd7a:115c:a1e0::1")
        XCTAssertEqual(
            ShareRequestInbox.sourceKey(from: "100.64.0.9"), "100.64.0.9",
            "an address with no port at all is already the key")
    }

    func testTwoIPv6PeersOnTheSamePrefixDoNotCollapse() {
        var inbox = ShareRequestInbox()
        inbox.record(
            fromHostname: "a", sourceAddr: "[fd7a:115c:a1e0::1]:1", connectionID: nil,
            nowNs: 0)
        inbox.record(
            fromHostname: "b", sourceAddr: "[fd7a:115c:a1e0::2]:1", connectionID: nil,
            nowNs: 0)
        XCTAssertEqual(inbox.requests.count, 2)
    }
}
