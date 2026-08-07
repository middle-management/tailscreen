import Foundation
import XCTest

@testable import TailscreenAudio

/// `VoiceLatch` — the microphone's two published flags, and what is allowed to
/// move them.
///
/// Five places wrote this inline before it was a type (the GTK viewer's
/// `VoiceControls`, the WinUI viewer's model, both share engines' voice blocks,
/// and the GTK viewer's `ViewerUIState`), and the wrong answers are all silent:
/// a control that says the microphone is live over a device recording nothing,
/// or a share that starts somebody talking before they meant to.
final class VoiceLatchTests: XCTestCase {

    /// Nothing is on the air until somebody presses the button. Both a share
    /// and a viewing session go through this transition.
    func testAttachIsAvailableAndMutedNeverLive() {
        var latch = VoiceLatch()
        XCTAssertFalse(latch.isAvailable)
        XCTAssertFalse(latch.isOn)

        let muted = latch.attach()
        XCTAssertTrue(muted, "the uplink must be told to start muted, not assumed to be")
        XCTAssertTrue(latch.isAvailable)
        XCTAssertFalse(latch.isOn, "opening a device must never put somebody on the air")
    }

    /// The hosts spell this `guard let uplink else { return }`. The value it
    /// hands back is what the uplink's `isMuted` takes, so the flag and the
    /// pipeline can never describe two different presses.
    func testToggleFlipsAndYieldsTheInverseForTheUplink() {
        var latch = VoiceLatch()
        latch.attach()

        XCTAssertEqual(
            latch.toggle(), .setMuted(false), "going live means un-muting the uplink")
        XCTAssertTrue(latch.isOn)

        XCTAssertEqual(latch.toggle(), .setMuted(true))
        XCTAssertFalse(latch.isOn)
    }

    /// **The bug this type was extracted to make unrepresentable.** Two hosts
    /// guarded their toggle on the *uplink* while publishing the *flags* — so a
    /// device that had already failed (uplink still held, `isAvailable` already
    /// false) could still be toggled into `isOn == true`. That is a live
    /// microphone indicator over a device recording nothing, which is the one
    /// wrong answer a mute control can give.
    func testToggleWithNothingAttachedMovesNothingAtAll() {
        var latch = VoiceLatch()
        XCTAssertEqual(
            latch.toggle(), .unchanged,
            "the signal that the uplink must not be touched either")
        XCTAssertFalse(latch.isAvailable)
        XCTAssertFalse(latch.isOn)

        // And after a failure, which is where the hosts' versions diverged.
        latch.attach()
        _ = latch.toggle()
        XCTAssertTrue(latch.isOn)
        latch.detach()
        XCTAssertEqual(latch.toggle(), .unchanged)
        XCTAssertFalse(latch.isOn, "a released device cannot be toggled back on the air")
    }

    /// A session ending and a device disappearing publish the same pair, which
    /// is why there is one transition rather than two that could disagree.
    func testDetachClearsBothFlagsTogether() {
        var latch = VoiceLatch()
        latch.attach()
        _ = latch.toggle()
        XCTAssertTrue(latch.isAvailable)
        XCTAssertTrue(latch.isOn)

        latch.detach()
        XCTAssertFalse(latch.isAvailable)
        XCTAssertFalse(latch.isOn)

        // Idempotent: every teardown path calls it, including ones that never
        // opened a device.
        latch.detach()
        XCTAssertEqual(latch, VoiceLatch())
    }

    /// Re-attaching after a failure starts a fresh, muted session rather than
    /// restoring whatever the person had chosen before the device vanished.
    func testReattachAfterAFailureStartsMutedAgain() {
        var latch = VoiceLatch()
        latch.attach()
        _ = latch.toggle()
        latch.detach()

        latch.attach()
        XCTAssertTrue(latch.isAvailable)
        XCTAssertFalse(latch.isOn)
    }
}
