import XCTest

@testable import TailscreenProtocol

/// Which microphone one global chord flips, and whether it's held at all.
/// Sharing and watching have separate mute latches; a hotkey muting "the
/// wrong one" is worse than none — the user believes they're silent and aren't.
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
        // "Mute from outside the window" is asymmetric: while sharing, the mic
        // button is behind the app you're demonstrating; while watching, the video window is what you're looking at.
        XCTAssertEqual(
            MuteHotkeyRouting.target(sharerMicAvailable: true, viewerMicAvailable: true),
            .sharer)
    }

    func testABrokenSharerMicDoesNotShadowTheViewer() {
        // "Available" means a live uplink, not a live session.
        XCTAssertEqual(
            MuteHotkeyRouting.target(sharerMicAvailable: false, viewerMicAvailable: true),
            .viewer)
    }

    func testNoMicrophoneRoutesNowhere() {
        XCTAssertNil(
            MuteHotkeyRouting.target(sharerMicAvailable: false, viewerMicAvailable: false))
    }

    func testRegistrationFollowsTheTarget() {
        // A global grab is exclusive — must not hold it with nothing to mute.
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
        // The label is how a host shows which mic the chord currently targets, since starting a share silently retargets it.
        let labels = Set(MuteHotkeyTarget.allCases.map(\.label))
        XCTAssertEqual(labels.count, MuteHotkeyTarget.allCases.count)
        for label in labels { XCTAssertFalse(label.isEmpty) }
    }
}
