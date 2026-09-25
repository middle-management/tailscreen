import Foundation
import XCTest

@testable import TailscreenAudio

/// `VoiceLatch` — the microphone's two published flags, and what is allowed to
/// move them. Wrong answers here are silent: a control claiming the mic is
/// live over a device recording nothing, or a share starting somebody talking
/// before they meant to.
final class VoiceLatchTests: XCTestCase {

    func testAttachIsAvailableAndMutedNeverLive() {
        var latch = VoiceLatch()
        XCTAssertFalse(latch.isAvailable)
        XCTAssertFalse(latch.isOn)

        let muted = latch.attach()
        XCTAssertTrue(muted, "the uplink must be told to start muted, not assumed to be")
        XCTAssertTrue(latch.isAvailable)
        XCTAssertFalse(latch.isOn, "opening a device must never put somebody on the air")
    }

    /// The value `toggle()` returns is what the uplink's `isMuted` takes, so
    /// the flag and the pipeline can never describe two different presses.
    func testToggleFlipsAndYieldsTheInverseForTheUplink() {
        var latch = VoiceLatch()
        latch.attach()

        XCTAssertEqual(
            latch.toggle(), .setMuted(false), "going live means un-muting the uplink")
        XCTAssertTrue(latch.isOn)

        XCTAssertEqual(latch.toggle(), .setMuted(true))
        XCTAssertFalse(latch.isOn)
    }

    /// The bug this type makes unrepresentable: toggling a device that
    /// already failed (uplink still held, `isAvailable` false) must not
    /// flip `isOn` true.
    func testToggleWithNothingAttachedMovesNothingAtAll() {
        var latch = VoiceLatch()
        XCTAssertEqual(
            latch.toggle(), .unchanged,
            "the signal that the uplink must not be touched either")
        XCTAssertFalse(latch.isAvailable)
        XCTAssertFalse(latch.isOn)

        latch.attach()
        _ = latch.toggle()
        XCTAssertTrue(latch.isOn)
        latch.detach()
        XCTAssertEqual(latch.toggle(), .unchanged)
        XCTAssertFalse(latch.isOn, "a released device cannot be toggled back on the air")
    }

    func testDetachClearsBothFlagsTogether() {
        var latch = VoiceLatch()
        latch.attach()
        _ = latch.toggle()
        XCTAssertTrue(latch.isAvailable)
        XCTAssertTrue(latch.isOn)

        latch.detach()
        XCTAssertFalse(latch.isAvailable)
        XCTAssertFalse(latch.isOn)

        // Idempotent: teardown paths call it even when no device was opened.
        latch.detach()
        XCTAssertEqual(latch, VoiceLatch())
    }

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
