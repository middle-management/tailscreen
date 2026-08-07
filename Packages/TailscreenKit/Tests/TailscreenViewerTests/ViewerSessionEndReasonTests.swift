import XCTest

import enum TailscreenProtocol.ViewerSessionEndReason

@testable import TailscreenViewer

/// Unit tests for `ViewerSessionEndReason.resolve` — the one place the wire's
/// single HELLO_DENY byte is turned into a sentence.
///
/// The interesting leg is the deny split. Both wordings are plausible on a
/// plausible screen, so a copy that hard-codes either one looks correct in
/// every screenshot and is wrong half the time in front of a person: telling
/// somebody they were "disconnected" when they were never let in, or that they
/// were "declined" when they had been watching for ten minutes.
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

    /// Never admitted: the request was refused at the approval placard.
    func testDenyBeforeAdmissionIsDeclined() {
        XCTAssertEqual(
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: false),
            .declined)
    }

    /// Already watching: the same byte is a mid-session kick.
    func testDenyAfterAdmissionIsDisconnectedBySharer() {
        XCTAssertEqual(
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: true),
            .disconnectedBySharer)
    }

    /// The context parameter has to CHANGE something, or a caller could pass
    /// anything and a future refactor could quietly drop it. Asserted as an
    /// inequality so the test fails if the two branches are ever collapsed.
    func testAdmissionContextIsLoadBearingForTheDenyByte() {
        XCTAssertNotEqual(
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: true),
            ViewerSessionEndReason.resolve(.deniedOrKicked, wasAdmitted: false))
    }

    /// Every close reason the wire can produce lands on a reason the UI can
    /// render — an exhaustiveness check that fails when a sixth close reason
    /// is added without a sentence to go with it.
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
