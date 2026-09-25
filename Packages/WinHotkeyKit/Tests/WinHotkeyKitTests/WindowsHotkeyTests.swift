import TailscreenProtocol
import XCTest

@testable import WinHotkeyKit

/// What can be checked about the Windows hotkey **off Windows**. No
/// `RegisterHotKey` here and nothing stands in for one, so this does not
/// verify a chord is taken, `WM_HOTKEY` reaches the pump thread, or the
/// thread shuts down cleanly — those need `winhotkey-probe` and
/// `winhotkey-probe --hold` on a real desk.
///
/// What it does verify: an unregistrable chord is refused before any
/// syscall, the stubbed platform reports itself honestly, and activations
/// drain the way the host's tick expects.
final class WindowsHotkeyTests: XCTestCase {

    func testTheStubbedPlatformSaysSoInsteadOfPretending() throws {
        try XCTSkipIf(WindowsHotkey.isSupported, "runs only where the shim is stubbed out")
        let chord = ShortcutChord(.character("m"), [.control, .option])
        switch WindowsHotkey.hold(chord) {
        case .failure(let reason):
            // Not `.alreadyOwned` — nothing owns it, there's simply no mechanism.
            XCTAssertEqual(reason, .unsupportedPlatform)
        case .success:
            XCTFail("a platform with no RegisterHotKey must not report success")
        }
    }

    func testAnUnmappableChordIsRefused() {
        // "+" is not a key (Shift and "="); a bare key would be taken from
        // every other application. Both refused before any registration.
        XCTAssertNil(
            WindowsHotkeyMapping.registration(for: ShortcutChord(.character("+"), [.primary])))
        XCTAssertNil(WindowsHotkeyMapping.registration(for: ShortcutChord(.character("m"))))
    }

    func testDrainReportsWhatThePumpCounted() {
        // Counts rather than latches — two presses inside one tick must both
        // land, or a quick mute/unmute reads as a single mute.
        var pending = [0, 1, 2, 0]
        let hotkey = WindowsHotkey(testingWith: { pending.isEmpty ? 0 : pending.removeFirst() })
        XCTAssertEqual(hotkey.drain(), 0)
        XCTAssertEqual(hotkey.drain(), 1)
        XCTAssertEqual(hotkey.drain(), 2)
        XCTAssertEqual(hotkey.drain(), 0)
    }

    func testReleasedHotkeyStopsReportingActivations() {
        let hotkey = WindowsHotkey(testingWith: { 3 })
        XCTAssertEqual(hotkey.drain(), 3)
        hotkey.takeForTesting = nil
        hotkey.release()
        XCTAssertEqual(hotkey.drain(), 0)
    }
}
