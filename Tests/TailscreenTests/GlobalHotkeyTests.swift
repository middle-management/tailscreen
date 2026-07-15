import Carbon.HIToolbox
import XCTest

@testable import Tailscreen

/// Pins the Carbon hotkey dispatch filter: each `GlobalHotkey` installs its
/// own event handler on the shared application event target, and Carbon
/// dispatches a hotkey-pressed event to every installed handler (most-recent
/// first, stopping at the first `noErr`). Without an id filter the
/// last-registered handler swallows *every* hotkey — the regression where
/// registering the remote-control revoke hotkey killed the mic toggle.
final class GlobalHotkeyTests: XCTestCase {
    private let signature = GlobalHotkey.signature

    func testHandlerFiresOnlyForMatchingID() {
        XCTAssertTrue(
            GlobalHotkey.handlerShouldFire(
                eventSignature: signature, eventID: 1, registeredSignature: signature, registeredID: 1))
        XCTAssertTrue(
            GlobalHotkey.handlerShouldFire(
                eventSignature: signature, eventID: 2, registeredSignature: signature, registeredID: 2))
    }

    func testHandlerIgnoresOtherHotkeysID() {
        // The revoke handler (id 2) must NOT fire for the mic hotkey (id 1),
        // and vice-versa — otherwise the last-installed one starves the other.
        XCTAssertFalse(
            GlobalHotkey.handlerShouldFire(
                eventSignature: signature, eventID: 1, registeredSignature: signature, registeredID: 2))
        XCTAssertFalse(
            GlobalHotkey.handlerShouldFire(
                eventSignature: signature, eventID: 2, registeredSignature: signature, registeredID: 1))
    }

    func testHandlerIgnoresForeignSignature() {
        let foreign = OSType(0x41424344)  // 'ABCD'
        XCTAssertFalse(
            GlobalHotkey.handlerShouldFire(
                eventSignature: foreign, eventID: 1, registeredSignature: signature, registeredID: 1))
    }
}
