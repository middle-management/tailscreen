import TailscreenProtocol
import XCTest

@testable import WinHotkeyKit

/// What can be checked about the Windows hotkey **off Windows**.
///
/// Read the scope honestly, the way `WASAPIKit`'s Linux leg states its own:
/// there is no `RegisterHotKey` here and nothing stands in for one, so this
/// does **not** verify that a chord is taken, that `WM_HOTKEY` reaches the pump
/// thread, or that the thread shuts down cleanly. Those need a Windows desk and
/// are covered by `winhotkey-probe` (which links the shim on the Windows CI
/// job) and, for the part only a person can see — that the chord fires while
/// another application is focused — `winhotkey-probe --hold`.
///
/// What it does verify is the wrapper's decisions and its non-Windows syntax:
/// that an unregistrable chord is refused before any syscall, that the
/// stubbed-out platform reports itself as such rather than pretending, and that
/// activations are drained the way the host's tick expects.
final class WindowsHotkeyTests: XCTestCase {

    func testTheStubbedPlatformSaysSoInsteadOfPretending() throws {
        try XCTSkipIf(WindowsHotkey.isSupported, "runs only where the shim is stubbed out")
        let chord = ShortcutChord(.character("m"), [.control, .option])
        switch WindowsHotkey.hold(chord) {
        case .failure(let reason):
            // Not `.alreadyOwned`: nothing owns it, there is simply no
            // mechanism. Collapsing the two would tell a Windows user to go
            // hunting for a conflicting app that does not exist.
            XCTAssertEqual(reason, .unsupportedPlatform)
        case .success:
            XCTFail("a platform with no RegisterHotKey must not report success")
        }
    }

    func testAnUnmappableChordIsRefused() {
        // "+" is not a key (it is Shift and "="), and a bare key would be taken
        // from every other application. Both are refused by the mapping, before
        // any registration is attempted.
        XCTAssertNil(
            WindowsHotkeyMapping.registration(for: ShortcutChord(.character("+"), [.primary])))
        XCTAssertNil(WindowsHotkeyMapping.registration(for: ShortcutChord(.character("m"))))
    }

    func testDrainReportsWhatThePumpCounted() {
        // MOD_NOREPEAT means the pump has already collapsed a held chord, so
        // the wrapper counts rather than latching — and two presses inside one
        // tick must both land, or a quick mute/unmute reads as a single mute.
        var pending = [0, 1, 2, 0]
        let hotkey = WindowsHotkey(testingWith: { pending.isEmpty ? 0 : pending.removeFirst() })
        XCTAssertEqual(hotkey.drain(), 0)
        XCTAssertEqual(hotkey.drain(), 1)
        XCTAssertEqual(hotkey.drain(), 2)
        XCTAssertEqual(hotkey.drain(), 0)
    }

    func testReleasedHotkeyStopsReportingActivations() {
        // Release has to mean now: the host releases the chord the moment the
        // last microphone goes away, and an activation surfacing after that
        // would toggle a mute that no longer exists.
        let hotkey = WindowsHotkey(testingWith: { 3 })
        XCTAssertEqual(hotkey.drain(), 3)
        hotkey.takeForTesting = nil
        hotkey.release()
        XCTAssertEqual(hotkey.drain(), 0)
    }
}
