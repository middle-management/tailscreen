import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Pins the menubar glyph precedence: active share beats everything,
/// active view beats requests, and a pending request-to-share only
/// surfaces while the app is fully idle (matching the popover banner's
/// suppression of queued requests during shares/connections).
final class MenubarIconStateTests: XCTestCase {
    func testActiveShareWinsOverEverything() {
        XCTAssertEqual(
            MenubarIconState.from(sharing: .active, connection: .viewing, hasPendingRequests: true),
            .sharing)
        XCTAssertEqual(
            MenubarIconState.from(sharing: .active, connection: .idle, hasPendingRequests: false),
            .sharing)
    }

    func testViewingWinsOverPendingRequests() {
        XCTAssertEqual(
            MenubarIconState.from(sharing: .idle, connection: .viewing, hasPendingRequests: true),
            .viewing)
    }

    func testRequestPendingOnlyWhenFullyIdle() {
        XCTAssertEqual(
            MenubarIconState.from(sharing: .idle, connection: .idle, hasPendingRequests: true),
            .requestPending)
        // Requests stay queued but invisible while a share or connection
        // is in flight — transitional states show the plain idle glyph.
        XCTAssertEqual(
            MenubarIconState.from(sharing: .starting, connection: .idle, hasPendingRequests: true),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(sharing: .idle, connection: .connecting, hasPendingRequests: true),
            .idle)
    }

    func testIdleWithoutRequests() {
        XCTAssertEqual(
            MenubarIconState.from(sharing: .idle, connection: .idle, hasPendingRequests: false),
            .idle)
        XCTAssertEqual(
            MenubarIconState.from(sharing: .starting, connection: .idle, hasPendingRequests: false),
            .idle)
    }
}
