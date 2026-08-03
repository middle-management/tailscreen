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

    /// **A Wayland session must never get X11 capture.**
    ///
    /// XWayland sets `$DISPLAY`, so the obvious "do we have a display?" gate
    /// passes on Wayland and the share succeeds — capturing the XWayland root,
    /// which holds only whichever X11 apps are running and is frequently empty.
    /// The sharer's UI says "Sharing". Viewers see a blank screen. Nothing
    /// errors anywhere.
    ///
    /// That is what the Linux app shipped before this type existed: its only
    /// gate was a non-empty `$DISPLAY`, and its "Wayland is not supported"
    /// message was therefore unreachable on any Wayland desktop with XWayland.
    func testAWaylandSessionNeverGetsX11CaptureEvenThoughDisplayIsSet() {
        let choice = CaptureBackendSelection.choose(
            intent: .entireScreen, environment: environment(session: .wayland, display: ":0"))
        XCTAssertEqual(choice, .portal)
    }

    /// And with no portal it must refuse, rather than falling back to the X11
    /// capture that would "work". A refusal a person can read beats a share
    /// that silently sends the wrong screen.
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

    /// X11 root capture cannot scope to a window. Widening the request to the
    /// whole screen would be a privacy failure, not a missing feature.
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

    /// Including on X11, where the whole-screen path would have worked — the
    /// point is that it is not what was asked for.
    func testAWindowShareUsesThePortalOnEverySessionKind() {
        for session in CaptureBackendSelection.SessionKind.allCases {
            let choice = CaptureBackendSelection.choose(
                intent: .windowOrApp, environment: environment(session: session))
            XCTAssertEqual(choice, .portal, "\(session)")
        }
    }

    // MARK: X11 keeps its silent path

    /// An X11 session sharing the whole screen keeps X11 capture even though
    /// the portal is available and can also do it. The portal would add a
    /// consent dialog to every share for no capability the person asked for.
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

    /// `DISPLAY=""` is common in service units and means the same as unset —
    /// but compares differently, and an empty display string reaches
    /// `XOpenDisplay` as a request to open the default, which is not what the
    /// caller meant.
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

    /// The display is carried through, not re-read from somewhere else — a
    /// share on `:1` must not capture `:0`.
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

    /// A compositor exports `WAYLAND_DISPLAY` even when nothing set the session
    /// type — so missing it here would put a Wayland desktop back on the X11
    /// path, which is the original bug.
    func testWaylandDisplayIsTheFallbackWhenNoSessionTypeIsSet() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["WAYLAND_DISPLAY": "wayland-0"]),
            .wayland)
    }

    /// **`DISPLAY` must not be consulted.** It is set under XWayland, so
    /// reading it as evidence of an X11 session is precisely the bug.
    func testDisplayAloneIsNotEvidenceOfAnX11Session() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["DISPLAY": ":0"]), .unknown)
        // And the pair that actually occurs on a Wayland desktop.
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(
                fromEnvironment: ["DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0"]), .wayland)
    }

    func testAnEmptyWaylandDisplayIsNotAWaylandSession() {
        XCTAssertEqual(
            CaptureBackendSelection.sessionKind(fromEnvironment: ["WAYLAND_DISPLAY": ""]), .unknown)
    }

    // MARK: Derived hub state

    /// The share button's enabled state is derived from `choose`, so the button
    /// and the share can never disagree about whether this machine can share.
    func testCanShareIsTrueWhenAnyIntentIsServable() {
        // Wayland with a portal: no X11 path at all, but still shareable.
        XCTAssertTrue(
            CaptureBackendSelection.canShareAnything(
                environment: environment(session: .wayland, display: nil, portal: true)))
        // X11 with no portal: no window shares, but the screen still works.
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
