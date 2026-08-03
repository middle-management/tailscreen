import TailscreenProtocol
import XCTest

@testable import X11HotkeyKit

/// The two halves of X11HotkeyKit that are decisions rather than Xlib calls:
/// whether to attempt a grab at all, and how a raw key-event stream becomes
/// activations.
///
/// The Xlib calls themselves are covered by `x11-hotkey-probe --live-check`,
/// which grabs the chord on a real server, synthesizes it through XTEST, and
/// then proves the refusal path by grabbing it twice.
final class X11HotkeyTests: XCTestCase {

    // MARK: - Should we even try?

    func testAnX11SessionIsSupported() {
        XCTAssertNil(
            X11HotkeySupport.decide(
                waylandDisplay: nil, sessionType: "x11", x11Display: ":0"))
    }

    func testWaylandIsRefusedEvenThoughXWaylandWouldAcceptTheGrab() {
        // The trap this exists for: XWayland sets DISPLAY and `XGrabKey`
        // succeeds against it, but XWayland only ever sees keystrokes routed
        // to X11 clients. The chord would work while an X11 app is focused and
        // do nothing otherwise — worse than absent, because it works often
        // enough to be trusted.
        XCTAssertEqual(
            X11HotkeySupport.decide(
                waylandDisplay: "wayland-0", sessionType: "wayland", x11Display: ":0"),
            .waylandSession)
    }

    func testWaylandWinsOverAPresentDisplay() {
        // Either signal alone is enough, and both are checked BEFORE DISPLAY —
        // treating a set DISPLAY as proof of an X11 session is exactly how
        // this ends up silently half-working.
        XCTAssertEqual(
            X11HotkeySupport.decide(
                waylandDisplay: "wayland-0", sessionType: nil, x11Display: ":0"),
            .waylandSession)
        XCTAssertEqual(
            X11HotkeySupport.decide(
                waylandDisplay: nil, sessionType: "Wayland", x11Display: ":0"),
            .waylandSession)
    }

    func testNoDisplayIsRefused() {
        XCTAssertEqual(
            X11HotkeySupport.decide(waylandDisplay: nil, sessionType: nil, x11Display: nil),
            .noDisplay)
        // An empty string is what an unset-but-present variable looks like.
        XCTAssertEqual(
            X11HotkeySupport.decide(waylandDisplay: "", sessionType: "tty", x11Display: ""),
            .noDisplay)
    }

    // MARK: - Raw events → activations

    private func hotkey(feeding events: [[GlobalHotkeyRepeatFilter.Event]]) -> X11Hotkey {
        var remaining = events
        return X11Hotkey(testingWith: {
            remaining.isEmpty ? [] : remaining.removeFirst()
        })
    }

    func testOnePressIsOneActivation() {
        let hotkey = hotkey(feeding: [[.press, .release]])
        XCTAssertEqual(hotkey.drain(), 1)
        XCTAssertEqual(hotkey.drain(), 0)
    }

    func testAHeldChordIsStillOneActivation() {
        // X11 has no MOD_NOREPEAT. Without the latch, leaning on the key would
        // flip the mute at the keyboard's repeat rate and leave it wherever
        // the finger came off.
        let hotkey = hotkey(feeding: [[.press, .press, .press, .press, .release]])
        XCTAssertEqual(hotkey.drain(), 1)
    }

    func testTwoPressesInOneTickCountTwice() {
        // Deliberately counted rather than collapsed to a Bool: two presses
        // inside one tick means the user toggled twice and expects to be back
        // where they started.
        let hotkey = hotkey(feeding: [[.press, .release, .press, .release]])
        XCTAssertEqual(hotkey.drain(), 2)
    }

    func testALatchSurvivesAcrossTicks() {
        // The repeat burst straddles a poll boundary — the state has to live
        // in the hotkey, not in one call.
        let hotkey = hotkey(feeding: [[.press, .press], [.press, .release], [.press]])
        XCTAssertEqual(hotkey.drain(), 1)
        XCTAssertEqual(hotkey.drain(), 0)
        XCTAssertEqual(hotkey.drain(), 1)
    }

    func testAnIdleTickReportsNothing() {
        let hotkey = hotkey(feeding: [[]])
        XCTAssertEqual(hotkey.drain(), 0)
    }

    func testReleaseWithoutADisplayReportsNoDisplay() {
        // The no-X path must not claim a grab it never took.
        let hotkey = hotkey(feeding: [[]])
        XCTAssertEqual(hotkey.grab(ShortcutChord(.character("m"), [.control, .option])), .noDisplay)
        XCTAssertFalse(hotkey.isGrabbed)
    }
}
