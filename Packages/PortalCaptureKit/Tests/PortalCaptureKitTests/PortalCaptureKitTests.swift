import XCTest

@testable import PortalCaptureKit

/// What can honestly be tested about a portal without a desktop session.
///
/// Nothing here touches a bus. The parts of the handshake that need one are
/// covered by `portal-probe --handshake-test` against a fake portal, and the
/// parts that need a compositor and a human are covered by nothing, because
/// nothing can cover them. See README.md.
final class PortalRequestPathTests: XCTestCase {
    /// The one piece of the handshake that is pure string arithmetic, and the
    /// one whose failure is completely silent: derive it wrong and the client
    /// subscribes to a path nothing is ever emitted on, so every portal call
    /// times out with no error from anywhere.
    ///
    /// Pinned against hand-written expectations rather than against the fake
    /// portal, which derives the same path with its own implementation — if
    /// both used one function, a typo would move both together and neither
    /// would notice.
    func testUniqueNameBecomesAPathElement() {
        XCTAssertEqual(
            PortalSession.requestPath(uniqueName: ":1.42", token: "ts9_1"),
            "/org/freedesktop/portal/desktop/request/1_42/ts9_1")
    }

    func testEveryDotBecomesAnUnderscore() {
        // Unique names are ":1.N" today, but the transform is defined over the
        // whole name and a bus that hands out ":1.2.3" must not produce an
        // object path with a dot in an element, which is illegal D-Bus.
        XCTAssertEqual(
            PortalSession.requestPath(uniqueName: ":1.2.3", token: "t"),
            "/org/freedesktop/portal/desktop/request/1_2_3/t")
    }

    func testNamesWithoutTheLeadingColonAreAccepted() {
        // The colon is the unique-name marker and is stripped, but a caller
        // passing an already-stripped name must get the same answer rather
        // than a silently different path.
        XCTAssertEqual(
            PortalSession.requestPath(uniqueName: "1.7", token: "t"),
            "/org/freedesktop/portal/desktop/request/1_7/t")
    }

    func testEmptyInputsAreRejectedRatherThanProducingAPath() {
        // A path with an empty element is not a legal object path, and
        // emitting one would fail deep inside libdbus with a message about
        // marshalling rather than about the empty token.
        XCTAssertNil(PortalSession.requestPath(uniqueName: ":1.1", token: ""))
        XCTAssertNil(PortalSession.requestPath(uniqueName: "", token: "t"))
        XCTAssertNil(PortalSession.requestPath(uniqueName: ":", token: "t"))
    }

    func testAnOverlongNameIsRejectedRatherThanTruncated() {
        // Truncation would produce a *valid-looking* path that no signal ever
        // arrives on — the same silent timeout as a typo, but harder to spot.
        let huge = ":1." + String(repeating: "9", count: 400)
        XCTAssertNil(PortalSession.requestPath(uniqueName: huge, token: "t"))
    }
}

final class PortalOptionMappingTests: XCTestCase {
    /// These are wire values in someone else's protocol. Naming them in Swift
    /// is only useful if the numbers are right, and a wrong one fails as
    /// "the picker offered the wrong thing", not as an error.
    func testSourceTypeBitsMatchThePortalSpecification() {
        XCTAssertEqual(PortalSession.SourceTypes.monitor.rawValue, 1)
        XCTAssertEqual(PortalSession.SourceTypes.window.rawValue, 2)
        XCTAssertEqual(PortalSession.SourceTypes.virtual.rawValue, 4)
        // The combination the sharer actually asks for, spelled out: it is what
        // makes "share one window" reachable on Linux at all.
        XCTAssertEqual(
            PortalSession.SourceTypes([.monitor, .window]).rawValue, 3)
    }

    func testCursorModeBitsMatchThePortalSpecification() {
        XCTAssertEqual(PortalSession.CursorMode.hidden.rawValue, 1)
        XCTAssertEqual(PortalSession.CursorMode.embedded.rawValue, 2)
        XCTAssertEqual(PortalSession.CursorMode.metadata.rawValue, 4)
    }

    func testPersistModeBitsMatchThePortalSpecification() {
        XCTAssertEqual(PortalSession.PersistMode.none.rawValue, 0)
        XCTAssertEqual(PortalSession.PersistMode.whileRunning.rawValue, 1)
        XCTAssertEqual(PortalSession.PersistMode.untilRevoked.rawValue, 2)
    }
}

final class PortalFailureMappingTests: XCTestCase {
    /// The distinction the sharer UI depends on: a person declining to share
    /// their screen is a normal outcome, and folding it into a generic error
    /// puts a failure dialog in front of somebody who did exactly what they
    /// meant to.
    func testACancelledRequestIsItsOwnCase() {
        XCTAssertEqual(
            PortalSession.Failure.from(code: -3, detail: "dismissed"),
            .cancelled)
    }

    func testMissingBusAndMissingPortalAreDistinguished() {
        // Different remedies: one means "you are headless", the other means
        // "install xdg-desktop-portal". Collapsing them sends users to the
        // wrong fix.
        XCTAssertEqual(
            PortalSession.Failure.from(code: -1, detail: "d"), .noSessionBus("d"))
        XCTAssertEqual(
            PortalSession.Failure.from(code: -2, detail: "d"), .portalUnavailable("d"))
    }

    func testConsentGivenButNothingToCaptureIsNotAPortalError() {
        // The user said yes and there is still nothing to share. Reporting it
        // as a portal failure would blame the desktop for an empty selection.
        XCTAssertEqual(
            PortalSession.Failure.from(code: -7, detail: "d"), .noStreams("d"))
    }

    func testAnUnknownCodeDegradesToAPortalErrorRatherThanCrashing() {
        // Portals are versioned and this enum is not the authority on what
        // they can return.
        guard case .portalError = PortalSession.Failure.from(code: -99, detail: "future") else {
            return XCTFail("an unknown code should read as a portal error")
        }
    }
}

final class PortalLinkTests: XCTestCase {
    /// Not a link check — a library target is compiled, not linked, so this
    /// cannot catch a missing `-lpipewire-0.3`. That is `portal-probe
    /// --link-check`'s job. This only asserts the wrapper returns something
    /// sane once linking has happened.
    func testPipeWireVersionIsReported() {
        XCTAssertFalse(PortalCapture.pipewireVersion.isEmpty)
    }
}
