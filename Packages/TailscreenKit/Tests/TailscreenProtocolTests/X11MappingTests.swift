import XCTest

@testable import TailscreenProtocol

/// The pure halves of the Linux sharer's remote-control path: HID → X11
/// keysym, and the delta/button arithmetic XTEST needs. Runs in
/// `linux-protocol` (no X server) — the split between *keysym* (protocol
/// constant, testable anywhere) and *keycode* (this machine's keymap,
/// testable nowhere) is what makes the interesting half checkable at all.
final class X11KeyCodeMappingTests: XCTestCase {
    func testLettersAndDigitsFoldToASCII() {
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x04), 0x0061)  // a
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x1D), 0x007A)  // z
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x1E), 0x0031)  // 1
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x26), 0x0039)  // 9
        // Zero is LAST in HID's ordering and first in ASCII's.
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x27), 0x0030)  // 0
    }

    /// Shift is delivered as a real key event around the keystroke; an
    /// uppercase keysym here would apply shift twice.
    func testLettersMapToLOWERCASEKeysyms() {
        for usage in UInt16(0x04)...UInt16(0x1D) {
            let keysym = X11KeyCodeMapping.keysym(forHIDUsage: usage)
            XCTAssertNotNil(keysym)
            XCTAssertTrue(
                (0x0061...0x007A).contains(keysym!),
                "HID 0x\(String(usage, radix: 16)) must map to a lowercase keysym")
        }
    }

    /// F1-F20 are contiguous on the X11 side while HID jumps 0x45 → 0x68.
    func testFunctionKeyRunsJoinWhereHIDDoesNot() {
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x3A), 0xFFBE)  // F1
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x45), 0xFFC9)  // F12
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x68), 0xFFCA)  // F13
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x6F), 0xFFD1)  // F20
    }

    /// Home and keypad-7 share a virtual key on Windows; X11 gives each its
    /// own keysym, so collapsing them here would make Home behave as
    /// keypad-7 whenever NumLock is off.
    func testNavigationAndKeypadTwinsAreDistinctKeysyms() {
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x4A), 0xFF50)  // Home
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x5F), 0xFFB7)  // keypad 7
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x28), 0xFF0D)  // Return
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x58), 0xFF8D)  // keypad Enter
    }

    /// XK_Left/Up/Right/Down are 0xFF51…0xFF54 in a non-obvious order —
    /// up is 0xFF52, not 0xFF51.
    func testArrowKeysAreNotRotated() {
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x4F), 0xFF53)  // Right
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x50), 0xFF51)  // Left
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x51), 0xFF54)  // Down
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x52), 0xFF52)  // Up
    }

    func testModifiersDistinguishLeftFromRight() {
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0xE0), 0xFFE3)  // LeftControl
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0xE4), 0xFFE4)  // RightControl
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0xE1), 0xFFE1)  // LeftShift
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0xE5), 0xFFE2)  // RightShift
    }

    /// Named rather than merely absent, so "chose not to map" is
    /// distinguishable from "forgot".
    func testDeliberatelyUnmappedIsExactAndDisjoint() {
        XCTAssertEqual(
            X11KeyCodeMapping.deliberatelyUnmapped, [0x67, 0x85, 0x87, 0x89, 0x90, 0x91])
        for usage in X11KeyCodeMapping.deliberatelyUnmapped {
            XCTAssertNil(
                X11KeyCodeMapping.keysym(forHIDUsage: usage),
                "0x\(String(usage, radix: 16)) is declared unmapped but has a mapping")
        }
    }

    func testModifierKeysymsExcludeCapsLockAndOrderIsStable() {
        XCTAssertEqual(
            X11KeyCodeMapping.modifierKeysyms([.control, .shift, .alt, .meta]),
            [0xFFE3, 0xFFE1, 0xFFE9, 0xFFEB])
        // Caps Lock is a toggle: a synthesized press leaves the sharer's
        // real Caps state flipped after the viewer disconnects.
        XCTAssertTrue(X11KeyCodeMapping.modifierKeysyms([.capsLock]).isEmpty)
    }

    /// HID names the context-menu key twice ("Application" 0x65, "Menu"
    /// 0x76), both landing on XK_Menu. Any OTHER duplicate would be a
    /// copy-paste error.
    func testOnlyTheContextMenuKeyIsDuplicated() {
        var seen: [UInt32: [UInt16]] = [:]
        for (usage, keysym) in X11KeyCodeMapping.keysymByHIDUsage {
            seen[keysym, default: []].append(usage)
        }
        let duplicates = seen.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
        XCTAssertEqual(duplicates, [0xFF67: [0x65, 0x76]])
    }
}

final class X11PointerMappingTests: XCTestCase {
    /// Truncation would discard every gesture smaller than a full line —
    /// the "my trackpad does nothing on Linux" bug.
    func testScrollRoundsRatherThanTruncating() {
        let small = X11PointerMapping.scroll(delta: 0.4, axis: .vertical)
        XCTAssertEqual(small?.count, 1)
        XCTAssertEqual(small?.button, .up)
    }

    /// Matches `WindowsPointerMapping.wheelDelta`'s sign convention so the
    /// same viewer gesture feels the same whichever sharer it reaches.
    func testScrollDirectionsFollowTheProtocolsSignConvention() {
        XCTAssertEqual(X11PointerMapping.scroll(delta: 1, axis: .vertical)?.button, .up)
        XCTAssertEqual(X11PointerMapping.scroll(delta: -1, axis: .vertical)?.button, .down)
        XCTAssertEqual(X11PointerMapping.scroll(delta: 1, axis: .horizontal)?.button, .right)
        XCTAssertEqual(X11PointerMapping.scroll(delta: -1, axis: .horizontal)?.button, .left)
    }

    /// Each notch is a real press+release pair on the X server, so an
    /// unbounded count is a denial-of-service vector that would freeze the
    /// sharer's desktop.
    func testScrollIsClampedSoAPeerCannotFloodTheServer() {
        XCTAssertEqual(
            X11PointerMapping.scroll(delta: 1e9, axis: .vertical)?.count,
            X11PointerMapping.maxNotchesPerEvent)
    }

    func testScrollIgnoresZeroAndNonFinite() {
        XCTAssertNil(X11PointerMapping.scroll(delta: 0, axis: .vertical))
        XCTAssertNil(X11PointerMapping.scroll(delta: .nan, axis: .vertical))
        XCTAssertNil(X11PointerMapping.scroll(delta: .infinity, axis: .vertical))
    }

    /// Middle is 2 and right is 3 — the opposite pairing to the wire enum's
    /// declaration order.
    func testButtonNumbersUseX11sOrderNotTheWireEnums() {
        XCTAssertEqual(X11PointerMapping.buttonNumber(.left), 1)
        XCTAssertEqual(X11PointerMapping.buttonNumber(.middle), 2)
        XCTAssertEqual(X11PointerMapping.buttonNumber(.right), 3)
    }
}

final class ScreenRegionTests: XCTestCase {
    func testFullRangeReachesTheLastPixel() {
        let region = ScreenRegion(x: 0, y: 0, width: 1920, height: 1080)
        // Off by one here makes the screen edge permanently unclickable.
        XCTAssertEqual(region.point(normalizedX: 1, normalizedY: 1).x, 1919)
        XCTAssertEqual(region.point(normalizedX: 1, normalizedY: 1).y, 1079)
        XCTAssertEqual(region.point(normalizedX: 0, normalizedY: 0).x, 0)
    }

    func testNegativeOriginIsHonoured() {
        let region = ScreenRegion(x: -1920, y: -200, width: 1920, height: 1080)
        assertPoint(region.point(normalizedX: 0, normalizedY: 0), -1920, -200)
    }

    /// A security boundary, not a convenience — stops a hostile viewer
    /// placing the pointer outside the visible region.
    func testOutOfRangeClampsRatherThanEscapingTheRegion() {
        let region = ScreenRegion(x: 100, y: 100, width: 800, height: 600)
        assertPoint(region.point(normalizedX: 5, normalizedY: 5), 899, 699)
        assertPoint(region.point(normalizedX: -5, normalizedY: -5), 100, 100)
    }

    func testNonFiniteMapsToTheOrigin() {
        let region = ScreenRegion(x: 10, y: 20, width: 800, height: 600)
        assertPoint(region.point(normalizedX: .nan, normalizedY: .infinity), 10, 20)
    }

    func testDegenerateRegionDoesNotTrap() {
        let region = ScreenRegion(x: 0, y: 0, width: 0, height: 0)
        assertPoint(region.point(normalizedX: 0.5, normalizedY: 0.5), 0, 0)
    }

    /// Swift tuples are not `Equatable`, so compared component-wise.
    private func assertPoint(
        _ actual: (x: Int, y: Int), _ x: Int, _ y: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            [actual.x, actual.y], [x, y],
            "expected (\(x), \(y)), got (\(actual.x), \(actual.y))", file: file, line: line)
    }
}
