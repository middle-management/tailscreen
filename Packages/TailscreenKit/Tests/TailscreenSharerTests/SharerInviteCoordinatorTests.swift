import Foundation
import TailscreenSharer
import TailscreenTransport
import XCTest

/// The sharer's invite sequencing (spec §13.3): pre-approve only on accept,
/// and never let an answer outlive the share it was sent for.
final class SharerInviteCoordinatorTests: XCTestCase {

    /// A send that parks until the test releases it with an outcome.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<ShareRequestOutcome, Never>] = []
        private var callCount = 0

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        func send() async -> ShareRequestOutcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                callCount += 1
                waiters.append(continuation)
                lock.unlock()
            }
        }

        func release(_ outcome: ShareRequestOutcome) {
            lock.lock()
            let all = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in all { waiter.resume(returning: outcome) }
        }

        var parked: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }
    }

    @MainActor
    private func settle(_ coordinator: SharerInviteCoordinator, ip: String) async {
        for _ in 0..<1000 where coordinator.statuses[ip] == .waiting {
            await Task.yield()
        }
    }

    @MainActor
    private func waitUntilParked(_ gate: Gate, _ count: Int) async {
        for _ in 0..<1000 where gate.parked < count {
            await Task.yield()
        }
    }

    @MainActor
    func testAcceptPreApprovesThePeer() async {
        let gate = Gate()
        let coordinator = SharerInviteCoordinator { _, _ in await gate.send() }
        var approved: [String] = []
        coordinator.onPreApproveViewer = { approved.append($0) }

        coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
        XCTAssertEqual(coordinator.statuses["100.64.0.7"], .waiting)
        await waitUntilParked(gate, 1)
        gate.release(.accepted)
        await settle(coordinator, ip: "100.64.0.7")

        XCTAssertEqual(coordinator.statuses["100.64.0.7"], .accepted)
        XCTAssertEqual(approved, ["100.64.0.7"])
    }

    @MainActor
    func testDeclineAndSilenceNeverPreApprove() async {
        for outcome in [ShareRequestOutcome.declined, .noAnswer] {
            let gate = Gate()
            let coordinator = SharerInviteCoordinator { _, _ in await gate.send() }
            var approved: [String] = []
            coordinator.onPreApproveViewer = { approved.append($0) }

            coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
            await waitUntilParked(gate, 1)
            gate.release(outcome)
            await settle(coordinator, ip: "100.64.0.7")

            XCTAssertEqual(
                coordinator.statuses["100.64.0.7"], outcome == .declined ? .declined : .noAnswer)
            XCTAssertTrue(approved.isEmpty, "TS-MET-026: \(outcome) is not approval")
        }
    }

    @MainActor
    func testSecondInviteWhileWaitingIsIgnored() async {
        let gate = Gate()
        let coordinator = SharerInviteCoordinator { _, _ in await gate.send() }
        coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
        coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
        await waitUntilParked(gate, 1)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(gate.calls, 1)
        gate.release(.noAnswer)
    }

    @MainActor
    func testReinviteAfterDeclineSendsAgain() async {
        let gate = Gate()
        let coordinator = SharerInviteCoordinator { _, _ in await gate.send() }
        coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
        await waitUntilParked(gate, 1)
        gate.release(.declined)
        await settle(coordinator, ip: "100.64.0.7")

        coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
        await waitUntilParked(gate, 1)
        XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(coordinator.statuses["100.64.0.7"], .waiting)
        gate.release(.noAnswer)
    }

    /// An accept that lands after Stop Sharing must not pre-approve into the
    /// next share. Paired with `testAcceptPreApprovesThePeer`, which proves
    /// the same accept does pre-approve while the share is live.
    @MainActor
    func testAcceptAfterEndShareIsIgnored() async {
        let gate = Gate()
        let coordinator = SharerInviteCoordinator { _, _ in await gate.send() }
        var approved: [String] = []
        coordinator.onPreApproveViewer = { approved.append($0) }

        coordinator.invite(ip: "100.64.0.7", fromHostname: "me")
        await waitUntilParked(gate, 1)
        coordinator.endShare()
        XCTAssertTrue(coordinator.statuses.isEmpty)

        gate.release(.accepted)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertTrue(approved.isEmpty)
        XCTAssertTrue(coordinator.statuses.isEmpty)
    }
}
