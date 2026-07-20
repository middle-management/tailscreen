import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Pins the menubar glyph precedence: active share beats everything,
/// active view beats requests, and a pending request-to-share only
/// surfaces while the app is fully idle (matching the popover banner's
/// suppression of queued requests during shares/connections). While
/// sharing, a pending remote-control request or a viewer waiting on the
/// approval gate badges the sharing glyph, with control outranking the
/// waiting viewer.
final class MenubarIconStateTests: XCTestCase {
    func testActiveShareWinsOverEverything() {
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .viewing,
                hasPendingRequests: true, hasControlRequests: false,
                hasWaitingViewers: false),
            .sharing)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .idle,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: false),
            .sharing)
    }

    func testControlRequestBadgesActiveShare() {
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .idle,
                hasPendingRequests: false, hasControlRequests: true,
                hasWaitingViewers: false),
            .sharingControlRequested)
        // Beats a simultaneous request-to-share and an active view — the
        // control prompt is the highest-stakes pending decision.
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .viewing,
                hasPendingRequests: true, hasControlRequests: true,
                hasWaitingViewers: false),
            .sharingControlRequested)
    }

    func testWaitingViewerBadgesActiveShare() {
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .idle,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: true),
            .sharingViewerWaiting)
        // Also wins over a simultaneous request-to-share, which stays
        // suppressed while a share is up.
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .viewing,
                hasPendingRequests: true, hasControlRequests: false,
                hasWaitingViewers: true),
            .sharingViewerWaiting)
    }

    func testControlRequestOutranksWaitingViewer() {
        // Both decisions pending at once: granting control of the Mac is
        // the higher-stakes prompt, so its badge wins.
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .active, connection: .idle,
                hasPendingRequests: false, hasControlRequests: true,
                hasWaitingViewers: true),
            .sharingControlRequested)
    }

    func testControlRequestIgnoredWhenNotActivelySharing() {
        // Control requests only exist while a share is up; a stale flag in
        // any other state must not badge a glyph that can't act on it.
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .idle,
                hasPendingRequests: false, hasControlRequests: true,
                hasWaitingViewers: false),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .starting, connection: .idle,
                hasPendingRequests: false, hasControlRequests: true,
                hasWaitingViewers: false),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .viewing,
                hasPendingRequests: false, hasControlRequests: true,
                hasWaitingViewers: false),
            .viewing)
    }

    func testWaitingViewerIgnoredWhenNotActivelySharing() {
        // Pending viewers likewise only exist while a share is up
        // (stopSharing clears them) — a stale flag must not badge the
        // idle or viewing glyphs.
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .idle,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: true),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .starting, connection: .idle,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: true),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .viewing,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: true),
            .viewing)
    }

    func testViewingWinsOverPendingRequests() {
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .viewing,
                hasPendingRequests: true, hasControlRequests: false,
                hasWaitingViewers: false),
            .viewing)
    }

    func testRequestPendingOnlyWhenFullyIdle() {
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .idle,
                hasPendingRequests: true, hasControlRequests: false,
                hasWaitingViewers: false),
            .requestPending)
        // Requests stay queued but invisible while a share or connection
        // is in flight — transitional states show the plain idle glyph.
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .starting, connection: .idle,
                hasPendingRequests: true, hasControlRequests: false,
                hasWaitingViewers: false),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .connecting,
                hasPendingRequests: true, hasControlRequests: false,
                hasWaitingViewers: false),
            .idle)
    }

    func testIdleWithoutRequests() {
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .idle, connection: .idle,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: false),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(
                sharing: .starting, connection: .idle,
                hasPendingRequests: false, hasControlRequests: false,
                hasWaitingViewers: false),
            .idle)
    }
}
