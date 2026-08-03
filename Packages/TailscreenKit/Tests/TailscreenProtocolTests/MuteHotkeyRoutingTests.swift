import XCTest

@testable import TailscreenProtocol

/// Which microphone one global chord flips, and whether it is held at all.
///
/// Small, and load-bearing: these apps can share and watch at once, the two
/// directions have separate mute latches on purpose, and a hotkey that muted
/// "the wrong one" would be worse than no hotkey — the user believes they are
/// silent and are not.
final class MuteHotkeyRoutingTests: XCTestCase {

    func testViewerOnlySessionRoutesToTheViewer() {
        XCTAssertEqual(
            MuteHotkeyRouting.target(sharerMicAvailable: false, viewerMicAvailable: true),
            .viewer)
    }

    func testShareOnlySessionRoutesToTheSharer() {
        XCTAssertEqual(
            MuteHotkeyRouting.target(sharerMicAvailable: true, viewerMicAvailable: false),
            .sharer)
    }

    func testSharerWinsWhenBothAreLive() {
        // The row this closes is "mute from outside the window", and being
        // outside the window is not symmetric: while sharing you are in the
        // app you are demonstrating, so the mic button is behind it. While
        // watching, the video window is the thing you are looking at.
        XCTAssertEqual(
            MuteHotkeyRouting.target(sharerMicAvailable: true, viewerMicAvailable: true),
            .sharer)
    }

    func testABrokenSharerMicDoesNotShadowTheViewer() {
        // "Available" is a live uplink, not a live session. If a share is up
        // but its capture device failed, the press must still reach the
        // microphone that exists rather than land on nothing.
        XCTAssertEqual(
            MuteHotkeyRouting.target(sharerMicAvailable: false, viewerMicAvailable: true),
            .viewer)
    }

    func testNoMicrophoneRoutesNowhere() {
        XCTAssertNil(
            MuteHotkeyRouting.target(sharerMicAvailable: false, viewerMicAvailable: false))
    }

    func testRegistrationFollowsTheTarget() {
        // A global grab is exclusive — holding the chord with nothing to mute
        // takes it from every other app on the machine for a handler with
        // nothing to do.
        XCTAssertFalse(
            MuteHotkeyRouting.shouldRegister(
                sharerMicAvailable: false, viewerMicAvailable: false))
        XCTAssertTrue(
            MuteHotkeyRouting.shouldRegister(sharerMicAvailable: true, viewerMicAvailable: false))
        XCTAssertTrue(
            MuteHotkeyRouting.shouldRegister(sharerMicAvailable: false, viewerMicAvailable: true))
        XCTAssertTrue(
            MuteHotkeyRouting.shouldRegister(sharerMicAvailable: true, viewerMicAvailable: true))
    }

    func testEveryTargetNamesItselfDistinctly() {
        // The label is how a host tells the user which microphone the chord is
        // currently pointed at — the mitigation for the one honest cost of
        // picking a winner, that starting a share silently retargets the key.
        let labels = Set(MuteHotkeyTarget.allCases.map(\.label))
        XCTAssertEqual(labels.count, MuteHotkeyTarget.allCases.count)
        for label in labels { XCTAssertFalse(label.isEmpty) }
    }
}
