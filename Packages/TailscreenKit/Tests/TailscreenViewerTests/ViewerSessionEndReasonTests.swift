import XCTest

import enum TailscreenProtocol.ViewerSessionEndReason

@testable import TailscreenViewer

/// Tests for `ViewerSessionEndReason.resolve` — turns the wire's single
/// HELLO_DENY byte into a sentence. The deny split matters because both
/// wordings look plausible on screen: telling someone they were
/// "disconnected" when never admitted, or "declined" after watching for
/// ten minutes, are both wrong.
final class ViewerSessionEndReasonTests: XCTestCase {
    func testNonDenyReasonsIgnoreAdmissionContext() {
        for wasAdmitted in [true, false] {
            XCTAssertEqual(
                ViewerSessionEndReason.resolve(.sharerStopped, wasAdmitted: wasAdmitted),
                .sharerStopped)
            XCTAssertEqual(
                ViewerSessionEndReason.resolve(.timedOut, wasAdmitted: wasAdmitted),
                .timedOut)
            XCTAssertEqual(
                ViewerSessionEndReason.resolve(.connectionLost, wasAdmitted: wasAdmitted),
                .connectionLost)
        }
    }

    func testDenyBeforeAdmissionIsDeclined() {
        XCTAssertEqual(
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: false),
            .declined)
    }

    func testDenyAfterAdmissionIsDisconnectedBySharer() {
        XCTAssertEqual(
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: true),
            .disconnectedBySharer)
    }

    /// Asserted as an inequality so the test fails if the two branches are
    /// ever collapsed.
    func testAdmissionContextIsLoadBearingForTheDenyByte() {
        XCTAssertNotEqual(
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: true),
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: false))
    }

    /// Exhaustiveness check: fails if a new close reason ships with no
    /// sentence to go with it.
    func testEveryCloseReasonResolves() {
        let all: [ViewerCloseReason] = [
            .sharerStopped, .timedOut, .connectionLost, .deniedOrKicked
        ]
        for reason in all {
            XCTAssertTrue(
                ViewerSessionEndReason.allCases.contains(
                    ViewerSessionEndReason.resolve(reason, wasAdmitted: true)))
        }
    }
}
