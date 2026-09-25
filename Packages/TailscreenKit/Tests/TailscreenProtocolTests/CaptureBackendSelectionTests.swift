import XCTest

@testable import TailscreenProtocol

/// `CaptureBackendSelection` — which capture backend a Linux share uses.
///
/// The decision has to be tested rather than exercised, for the usual reason:
/// the portal branch ends in a consent dialog a person clicks, so no CI leg can
/// follow it. What CI *can* do is pin every branch, and in particular pin the
/// one that used to be wrong.
final class CaptureBackendSelectionTests: XCTestCase {

    private func environment(
        session: CaptureBackendSelection.SessionKind,
        display: String? = ":0",
        portal: Bool = true
    ) -> CaptureBackendSelection.Environment {
        CaptureBackendSelection.Environment(
            session: session, x11Display: display, portalAvailable: portal)
    }

    // MARK: The bug this type exists for

    /// XWayland sets `$DISPLAY`, so a naive "do we have a display?" gate
    /// passes on Wayland and captures the XWayland root — frequently empty,
    /// with the sharer saying "Sharing" and viewers seeing a blank screen.
    func testAWaylandSessionNeverGetsX11CaptureEvenThoughDisplayIsSet() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen, environment: environment(session: .wayland, display: ":0"))
        XCTAssertEqual(choice, .portal)
    }

    /// A refusal a person can read beats a share that silently sends the
    /// wrong screen.
    func testAWaylandSessionWithNoPortalRefusesRatherThanFallingBackToX11() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen,
            environment: environment(session: .wayland, display: ":0", portal: false))
        guard case .unavailable(let reason) = choice else {
            return XCTFail("expected a refusal, got \(choice)")
        }
        XCTAssertTrue(
            reason.lowercased().contains("wayland"),
            "the reason must say what is actually wrong: \(reason)")
    }

    // MARK: Window and app shares

    /// Widening the request to the whole screen would be a privacy failure,
    /// not a missing feature.
    func testAWindowShareWithoutAPortalIsRefusedAndNotWidenedToTheScreen() {
        for session in CaptureBackendSelection.SessionKind.allCases {
            let choice = CaptureBackendSelection.choose(
                intent: .windowOrApp,
                environment: environment(session: session, display: ":0", portal: false))
            guard case .unavailable = choice else {
                return XCTFail("\(session): a window share must not fall back, got \(choice)")
            }
        }
    }

    /// Including on X11, where the whole-screen path would have worked.
    func testAWindowShareUsesThePortalOnEverySessionKind() {
        for session in CaptureBackendSelection.SessionKind.allCases {
            let choice = CaptureBackendSelection.choose(
                intent: .windowOrApp, environment: environment(session: session))
            XCTAssertEqual(choice, .portal, "\(session)")
        }
    }

    // MARK: X11 keeps its silent path

    /// The portal would add a consent dialog for no capability the person
    /// asked for.
    func testAnX11ScreenShareStaysOnX11EvenWhenThePortalIsAvailable() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen, environment: environment(session: .x11, portal: true))
        XCTAssertEqual(choice, .x11(display: ":0"))
    }

    /// `startx`, containers and forwarded SSH sessions set no
    /// `XDG_SESSION_TYPE` and are genuinely X11.
    func testAnUnknownSessionWithADisplayIsTreatedAsX11() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen, environment: environment(session: .unknown))
        XCTAssertEqual(choice, .x11(display: ":0"))
    }

    func testAnX11SessionWithNoDisplayFallsBackToThePortal() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen, environment: environment(session: .x11, display: nil))
        XCTAssertEqual(choice, .portal)
    }

    /// `DISPLAY=""` means the same as unset, but an empty string reaches
    /// `XOpenDisplay` as a request to open the default.
    func testAnEmptyDisplayStringCountsAsNoDisplay() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen,
            environment: environment(session: .unknown, display: "", portal: true))
        XCTAssertEqual(choice, .portal)
    }

    func testNoDisplayAndNoPortalIsRefused() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen,
            environment: environment(session: .unknown, display: nil, portal: false))
        guard case .unavailable = choice else {
            return XCTFail("expected a refusal, got \(choice)")
        }
    }

    func testTheChosenDisplayIsTheOneThatWasPassedIn() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen, environment: environment(session: .x11, display: ":7"))
        XCTAssertEqual(choice, .x11(display: ":7"))
    }

    // MARK: Session detection

    func testSessionKindReadsXDGSessionTypeFirst() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["XDG_SESSION_TYPE": "wayland"]),
            .wayland)
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["XDG_SESSION_TYPE": "x11"]), .x11)
    }

    func testSessionKindIsCaseInsensitive() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["XDG_SESSION_TYPE": "Wayland"]),
            .wayland)
    }

    /// Missing this would put a Wayland desktop back on the X11 path.
    func testWaylandDisplayIsTheFallbackWhenNoSessionTypeIsSet() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["WAYLAND_DISPLAY": "wayland-0"]),
            .wayland)
    }

    /// `DISPLAY` must not be consulted — it's set under XWayland too.
    func testDisplayAloneIsNotEvidenceOfAnX11Session() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["DISPLAY": ":0"]), .unknown)
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(
                fromEnvironment: ["DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0"]), .wayland)
    }

    func testAnEmptyWaylandDisplayIsNotAWaylandSession() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["WAYLAND_DISPLAY": ""]), .unknown)
    }

    // MARK: Derived hub state

    func testCanShareIsTrueWhenAnyIntentIsServable() {
        XCTAssertTrue(
            CaptureBackendSelection.canShareAnything(
                environment: environment(session: .wayland, display: nil, portal: true)))
        XCTAssertTrue(
            CaptureBackendSelection.canShareAnything(
                environment: environment(session: .x11, portal: false)))
    }

    func testCanShareIsFalseWhenNothingIsServable() {
        XCTAssertFalse(
            CaptureBackendSelection.canShareAnything(
                environment: environment(session: .wayland, display: ":0", portal: false)))
        XCTAssertFalse(
            CaptureBackendSelection.canShareAnything(
                environment: environment(session: .unknown, display: nil, portal: false)))
    }

    func testAnAvailableEnvironmentHasNoUnavailableReason() {
        XCTAssertNil(
            CaptureBackendSelection.unavailableReason(environment: environment(session: .x11)))
    }

    func testAnUnavailableEnvironmentExplainsItself() {
        let reason = CaptureBackendSelection.unavailableReason(
            environment: environment(session: .wayland, display: ":0", portal: false))
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.isEmpty ?? true)
    }
}
