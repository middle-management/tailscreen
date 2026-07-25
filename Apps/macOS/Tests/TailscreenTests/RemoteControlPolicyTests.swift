import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenSharer
@testable import TailscreenTransport

/// Pure tests for the remote-control grant gate, mouse-move coalescing, and
/// the event rate limiter — the security-critical and flood-control decisions
/// extracted from the async server/injector so they're CI-able.
final class RemoteControlPolicyTests: XCTestCase {

    private func grant(_ connectionID: UUID) -> ControlGrant {
        ControlGrant(
            connectionID: connectionID, viewerIP: "100.64.0.2", stableID: "n123", hostname: "peer",
            grantedAt: Date())
    }

    // MARK: - shouldInject gate

    func testGateAdmitsOnlyTheGranteeConnection() {
        let grantee = UUID()
        let other = UUID()
        XCTAssertTrue(RemoteControlPolicy.shouldInject(grant: grant(grantee), connectionID: grantee))
        XCTAssertFalse(RemoteControlPolicy.shouldInject(grant: grant(grantee), connectionID: other))
    }

    func testGateDeniesWhenNobodyHoldsControl() {
        XCTAssertFalse(RemoteControlPolicy.shouldInject(grant: nil, connectionID: UUID()))
    }

    // MARK: - Mouse-move coalescing

    func testCoalesceKeepsOnlyLastOfConsecutiveMoves() {
        let events: [InputEvent] = [
            .mouseMove(x: 0.1, y: 0.1),
            .mouseMove(x: 0.2, y: 0.2),
            .mouseMove(x: 0.3, y: 0.3)
        ]
        let coalesced = RemoteControlPolicy.coalesceMouseMoves(events)
        XCTAssertEqual(coalesced, [.mouseMove(x: 0.3, y: 0.3)])
    }

    func testCoalesceNeverDropsButtonScrollOrKeyEvents() {
        let events: [InputEvent] = [
            .mouseMove(x: 0.1, y: 0.1),
            .mouseMove(x: 0.2, y: 0.2),
            .mouseDown(x: 0.2, y: 0.2, button: .left, modifiers: []),
            .mouseMove(x: 0.3, y: 0.3),
            .mouseUp(x: 0.3, y: 0.3, button: .left, modifiers: []),
            .scroll(x: 0.3, y: 0.3, deltaX: 0, deltaY: -2, modifiers: []),
            .keyDown(key: 4, modifiers: []),
            .keyUp(key: 4, modifiers: [])
        ]
        let coalesced = RemoteControlPolicy.coalesceMouseMoves(events)
        // The first move is superseded by the second; the move before the
        // click and the move before the up survive (no move follows them).
        XCTAssertEqual(
            coalesced,
            [
                .mouseMove(x: 0.2, y: 0.2),
                .mouseDown(x: 0.2, y: 0.2, button: .left, modifiers: []),
                .mouseMove(x: 0.3, y: 0.3),
                .mouseUp(x: 0.3, y: 0.3, button: .left, modifiers: []),
                .scroll(x: 0.3, y: 0.3, deltaX: 0, deltaY: -2, modifiers: []),
                .keyDown(key: 4, modifiers: []),
                .keyUp(key: 4, modifiers: [])
            ])
    }

    func testCoalesceIsIdentityWithoutConsecutiveMoves() {
        let events: [InputEvent] = [
            .mouseDown(x: 0, y: 0, button: .left, modifiers: []),
            .mouseUp(x: 0, y: 0, button: .left, modifiers: [])
        ]
        XCTAssertEqual(RemoteControlPolicy.coalesceMouseMoves(events), events)
    }

    // MARK: - Rate limiter

    func testRateLimiterCapsWithinWindow() {
        var limiter = EventRateLimiter(maxEventsPerWindow: 3, windowNs: 1_000_000_000)
        XCTAssertTrue(limiter.allow(nowNs: 0))
        XCTAssertTrue(limiter.allow(nowNs: 1))
        XCTAssertTrue(limiter.allow(nowNs: 2))
        // Fourth in the same window is over budget.
        XCTAssertFalse(limiter.allow(nowNs: 3))
    }

    func testRateLimiterRecoversAfterWindowElapses() {
        var limiter = EventRateLimiter(maxEventsPerWindow: 2, windowNs: 1_000_000_000)
        XCTAssertTrue(limiter.allow(nowNs: 0))
        XCTAssertTrue(limiter.allow(nowNs: 100))
        XCTAssertFalse(limiter.allow(nowNs: 200))
        // Past the window, the old stamps prune and budget frees up.
        XCTAssertTrue(limiter.allow(nowNs: 1_000_000_500))
    }

    func testRateLimiterDoesNotRecordOverBudgetEvents() {
        // A sustained flood must stay capped at the ceiling, not pin the
        // window permanently full: dropped events aren't recorded, so once
        // the earliest accepted stamp ages out, one slot frees.
        var limiter = EventRateLimiter(maxEventsPerWindow: 1, windowNs: 1_000_000_000)
        XCTAssertTrue(limiter.allow(nowNs: 0))
        XCTAssertFalse(limiter.allow(nowNs: 500_000_000))
        XCTAssertFalse(limiter.allow(nowNs: 999_000_000))
        XCTAssertTrue(limiter.allow(nowNs: 1_000_000_001))
    }

    // MARK: - Control-request notification dedupe (per viewer IP per share)

    private func request(_ ip: String, id: UUID = UUID()) -> ControlRequestInfo {
        ControlRequestInfo(id: id, viewerIP: ip, hostname: nil, arrivedAt: Date())
    }

    func testNotificationDedupeFiresOncePerPendingEpisode() {
        let first = request("100.64.0.7")
        let initial = AppState.controlRequestNotificationDecision(
            requests: [first], previouslyNotifiedIPs: [])
        XCTAssertEqual(initial.notify.map(\.id), [first.id])
        XCTAssertEqual(initial.notifiedIPs, ["100.64.0.7"])

        // A refresh/reconnect while the IP still has a live pending request
        // (fresh connection UUID, same IP) must not re-notify. The
        // connectionID-keyed dedupe this replaces notified on every one.
        let respam = request("100.64.0.7")
        let second = AppState.controlRequestNotificationDecision(
            requests: [respam], previouslyNotifiedIPs: initial.notifiedIPs)
        XCTAssertTrue(second.notify.isEmpty, "a still-pending IP must not re-notify")
        XCTAssertEqual(second.notifiedIPs, ["100.64.0.7"])
    }

    func testNotificationDedupeReNotifiesAfterRequestLeavesPending() {
        // Deny / grant / release / disconnect all remove the request from
        // the pending snapshot; the notified-IP set must forget the IP then,
        // so a genuine re-request fires a fresh notification (same
        // forget-on-leave semantics as the viewer-join notifications).
        let first = request("100.64.0.7")
        let initial = AppState.controlRequestNotificationDecision(
            requests: [first], previouslyNotifiedIPs: [])
        XCTAssertEqual(initial.notify.count, 1)

        // The request is denied → snapshot no longer contains the IP.
        let afterDeny = AppState.controlRequestNotificationDecision(
            requests: [], previouslyNotifiedIPs: initial.notifiedIPs)
        XCTAssertTrue(afterDeny.notify.isEmpty)
        XCTAssertTrue(afterDeny.notifiedIPs.isEmpty, "an IP with no live request must be forgotten")

        // A genuine re-request from the same viewer notifies again.
        let again = request("100.64.0.7")
        let third = AppState.controlRequestNotificationDecision(
            requests: [again], previouslyNotifiedIPs: afterDeny.notifiedIPs)
        XCTAssertEqual(third.notify.map(\.id), [again.id], "a re-request after deny must notify")
    }

    func testNotificationDedupeStillNotifiesNewIPs() {
        let known = request("100.64.0.7")
        let newcomer = request("100.64.0.9")
        let decision = AppState.controlRequestNotificationDecision(
            requests: [known, newcomer], previouslyNotifiedIPs: ["100.64.0.7"])
        XCTAssertEqual(decision.notify.map(\.viewerIP), ["100.64.0.9"])
        XCTAssertEqual(decision.notifiedIPs, ["100.64.0.7", "100.64.0.9"])
    }

    func testNotificationDedupeNotifiesOneIPOncePerBatch() {
        // Two live requests from the same IP in one snapshot (parallel
        // connections): a single notification.
        let a = request("100.64.0.7")
        let b = request("100.64.0.7")
        let decision = AppState.controlRequestNotificationDecision(
            requests: [a, b], previouslyNotifiedIPs: [])
        XCTAssertEqual(decision.notify.count, 1)
        XCTAssertEqual(decision.notifiedIPs, ["100.64.0.7"])
    }

    // MARK: - Grant-change generation ordering

    func testStaleGrantNotificationIsDropped() {
        // The MainActor hop can reorder grant-change deliveries; only
        // notifications with a generation >= the last applied one may apply.
        XCTAssertTrue(AppState.isStaleGrantNotification(generation: 1, lastApplied: 2))
        XCTAssertFalse(
            AppState.isStaleGrantNotification(generation: 2, lastApplied: 2),
            "equal generations re-apply idempotently — two notifies can read the same state")
        XCTAssertFalse(AppState.isStaleGrantNotification(generation: 3, lastApplied: 2))
        XCTAssertFalse(AppState.isStaleGrantNotification(generation: 1, lastApplied: 0))
    }

    // MARK: - Toggle-off drains pending requests

    func testDisablingControlRequestsDrainsPendingRequests() {
        // "Turn off to decline requests automatically" (Settings caption):
        // flipping the gate off must clear every parked request so the
        // sharer's pending rows empty and each requester is declined.
        // Snapshots arrive synchronously via onControlRequestsChanged; no
        // live listener needed (the .controlRevoked reply no-ops headless).
        final class SnapshotBox: @unchecked Sendable {
            private let lock = NSLock()
            private var snapshots: [[ControlRequestInfo]] = []
            func append(_ snapshot: [ControlRequestInfo]) {
                lock.lock()
                defer { lock.unlock() }
                snapshots.append(snapshot)
            }
            var last: [ControlRequestInfo] {
                lock.lock()
                defer { lock.unlock() }
                return snapshots.last ?? []
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return snapshots.count
            }
        }
        let box = SnapshotBox()
        let server = TailscaleScreenShareServer()
        server.onControlRequestsChanged = { box.append($0) }

        server.recordControlRequestForTesting(connectionID: UUID(), ip: "100.64.0.7")
        server.recordControlRequestForTesting(connectionID: UUID(), ip: "100.64.0.9")
        XCTAssertEqual(box.last.count, 2, "both requests should be parked")

        server.setAllowControlRequests(false)
        XCTAssertEqual(box.last.count, 0, "toggle-off must drain every pending request")

        // And with the gate off, nothing new piles up via the drain path;
        // flipping back on doesn't resurrect the drained requests either.
        let snapshotsAfterDrain = box.count
        server.setAllowControlRequests(true)
        XCTAssertEqual(box.count, snapshotsAfterDrain, "re-enabling must not emit a new snapshot")
    }

    // MARK: - RemoteControlDefaults persistence

    func testRemoteControlDefaultsDefaultOnAndRoundTrip() throws {
        let suiteName = "RemoteControlDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(
            RemoteControlDefaults.load(defaults: defaults),
            "allowControlRequests must default on for untouched installs")
        RemoteControlDefaults.save(false, defaults: defaults)
        XCTAssertFalse(RemoteControlDefaults.load(defaults: defaults), "explicit opt-out sticks")
        RemoteControlDefaults.save(true, defaults: defaults)
        XCTAssertTrue(RemoteControlDefaults.load(defaults: defaults))
    }
}
