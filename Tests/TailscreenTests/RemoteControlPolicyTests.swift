import XCTest

@testable import Tailscreen

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
            .mouseDown(x: 0.2, y: 0.2, button: .left),
            .mouseMove(x: 0.3, y: 0.3),
            .mouseUp(x: 0.3, y: 0.3, button: .left),
            .scroll(x: 0.3, y: 0.3, deltaX: 0, deltaY: -2),
            .keyDown(keyCode: 4, modifiers: 0),
            .keyUp(keyCode: 4, modifiers: 0)
        ]
        let coalesced = RemoteControlPolicy.coalesceMouseMoves(events)
        // The first move is superseded by the second; the move before the
        // click and the move before the up survive (no move follows them).
        XCTAssertEqual(
            coalesced,
            [
                .mouseMove(x: 0.2, y: 0.2),
                .mouseDown(x: 0.2, y: 0.2, button: .left),
                .mouseMove(x: 0.3, y: 0.3),
                .mouseUp(x: 0.3, y: 0.3, button: .left),
                .scroll(x: 0.3, y: 0.3, deltaX: 0, deltaY: -2),
                .keyDown(keyCode: 4, modifiers: 0),
                .keyUp(keyCode: 4, modifiers: 0)
            ])
    }

    func testCoalesceIsIdentityWithoutConsecutiveMoves() {
        let events: [InputEvent] = [
            .mouseDown(x: 0, y: 0, button: .left),
            .mouseUp(x: 0, y: 0, button: .left)
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
}
