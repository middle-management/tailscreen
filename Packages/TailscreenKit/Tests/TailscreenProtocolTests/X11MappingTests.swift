import XCTest

@testable import TailscreenProtocol

/// The pure halves of the Linux sharer's remote-control path: HID → X11
/// keysym, and the delta/button arithmetic XTEST needs.
///
/// Here rather than in XTestInjectKit because that is where the subject types
/// live, and because these run in `linux-protocol` — a job with no X server,
/// which is the point: the split between *keysym* (protocol constant, testable
/// anywhere) and *keycode* (this machine's keymap, testable nowhere) is what
/// makes the interesting half checkable at all.
final class X11KeyCodeMappingTests: XCTestCase {
    func testLettersAndDigitsFoldToASCII() {
        // The programmatic runs, which are where an off-by-one would shift
        // every key in the range at once.
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x04), 0x0061)  // a
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x1D), 0x007A)  // z
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x1E), 0x0031)  // 1
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x26), 0x0039)  // 9
        // Zero is LAST in HID's ordering and first in ASCII's — the one place
        // the two sequences disagree, so the one that a loop gets wrong.
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x27), 0x0030)  // 0
    }

    func testLettersMapToLOWERCASEKeysyms() {
        // Shift is delivered as a real key event around the keystroke, so an
        // uppercase keysym here would apply shift twice. The symptom is that
        // capitals arrive as something else entirely on some layouts, which
        // reads as "the keyboard is broken" rather than as a case bug.
        for usage in UInt16(0x04)...UInt16(0x1D) {
            let keysym = X11KeyCodeMapping.keysym(forHIDUsage: usage)
            XCTAssertNotNil(keysym)
            XCTAssertTrue(
                (0x0061...0x007A).contains(keysym!),
                "HID 0x\(String(usage, radix: 16)) must map to a lowercase keysym")
        }
    }

    func testFunctionKeyRunsJoinWhereHIDDoesNot() {
        // F1–F12 and F13–F20 are contiguous with EACH OTHER on the X11 side
        // (0xFFC9 is F12, 0xFFCA is F13) while the HID side jumps 0x45 → 0x68.
        // A loop written across the join would silently shift F13 upward.
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x3A), 0xFFBE)  // F1
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x45), 0xFFC9)  // F12
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x68), 0xFFCA)  // F13
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x6F), 0xFFD1)  // F20
    }

    func testNavigationAndKeypadTwinsAreDistinctKeysyms() {
        // The case that forced the Windows table to key on (code, extended):
        // there, Home and keypad-7 share a virtual key. X11 gives each its own
        // keysym, which is why this table is a plain UInt32 — and this pins
        // that they really are different, since collapsing them would make
        // Home behave as keypad-7 whenever NumLock is off.
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x4A), 0xFF50)  // Home
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x5F), 0xFFB7)  // keypad 7
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x28), 0xFF0D)  // Return
        XCTAssertEqual(X11KeyCodeMapping.keysym(forHIDUsage: 0x58), 0xFF8D)  // keypad Enter
    }

    func testArrowKeysAreNotRotated() {
        // XK_Left/Up/Right/Down are 0xFF51…0xFF54 in an order that is not the
        // obvious one — up is 0xFF52, not 0xFF51. Getting it wrong rotates
        // every arrow key by one, which is both very obvious in use and very
        // easy to write.
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

    func testDeliberatelyUnmappedIsExactAndDisjoint() {
        // Named rather than merely absent, so "we chose not to map this" is
        // distinguishable from "we forgot" — and asserting the set exactly
        // makes adding one later a deliberate act rather than a silent
        // widening.
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
        // Caps Lock is a toggle: synthesizing a press flips the sharer's real
        // Caps state and leaves it flipped after the viewer disconnects.
        XCTAssertTrue(X11KeyCodeMapping.modifierKeysyms([.capsLock]).isEmpty)
    }

    func testOnlyTheContextMenuKeyIsDuplicated() {
        // HID names the context-menu key twice — "Application" (0x65) and
        // "Menu" (0x76) — and keyboards send either, so both land on XK_Menu.
        // Every OTHER duplicate would be a copy-paste error: two keys that
        // inject the same symbol, with no symptom until someone presses the
        // wrong one.
        var seen: [UInt32: [UInt16]] = [:]
        for (usage, keysym) in X11KeyCodeMapping.keysymByHIDUsage {
            seen[keysym, default: []].append(usage)
        }
        let duplicates = seen.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
        XCTAssertEqual(duplicates, [0xFF67: [0x65, 0x76]])
    }
}

final class X11PointerMappingTests: XCTestCase {
    func testScrollRoundsRatherThanTruncating() {
        // Truncation would silently discard every gesture smaller than a full
        // line — the "my trackpad does nothing on Linux" bug, which looks like
        // a driver problem rather than a rounding one.
        let small = X11PointerMapping.scroll(delta: 0.4, axis: .vertical)
        XCTAssertEqual(small?.count, 1)
        XCTAssertEqual(small?.button, .up)
    }

    func testScrollDirectionsFollowTheProtocolsSignConvention() {
        // Positive is away-from-user vertically and rightward horizontally,
        // matching WindowsPointerMapping.wheelDelta so the same viewer gesture
        // feels the same whichever sharer it reaches.
        XCTAssertEqual(X11PointerMapping.scroll(delta: 1, axis: .vertical)?.button, .up)
        XCTAssertEqual(X11PointerMapping.scroll(delta: -1, axis: .vertical)?.button, .down)
        XCTAssertEqual(X11PointerMapping.scroll(delta: 1, axis: .horizontal)?.button, .right)
        XCTAssertEqual(X11PointerMapping.scroll(delta: -1, axis: .horizontal)?.button, .left)
    }

    func testScrollIsClampedSoAPeerCannotFloodTheServer() {
        // Each notch is a real press+release pair on the X server, so an
        // unbounded count is a denial-of-service vector from a peer sending a
        // large delta — and would freeze the sharer's desktop, not merely
        // scroll a lot.
        XCTAssertEqual(
            X11PointerMapping.scroll(delta: 1e9, axis: .vertical)?.count,
            X11PointerMapping.maxNotchesPerEvent)
    }

    func testScrollIgnoresZeroAndNonFinite() {
        XCTAssertNil(X11PointerMapping.scroll(delta: 0, axis: .vertical))
        XCTAssertNil(X11PointerMapping.scroll(delta: .nan, axis: .vertical))
        XCTAssertNil(X11PointerMapping.scroll(delta: .infinity, axis: .vertical))
    }

    func testButtonNumbersUseX11sOrderNotTheWireEnums() {
        // Middle is 2 and right is 3 — the opposite pairing to the wire enum's
        // declaration order, which is exactly why this is a named function
        // with a test rather than an inline `rawValue + 1`.
        XCTAssertEqual(X11PointerMapping.buttonNumber(.left), 1)
        XCTAssertEqual(X11PointerMapping.buttonNumber(.middle), 2)
        XCTAssertEqual(X11PointerMapping.buttonNumber(.right), 3)
    }
}

final class ScreenRegionTests: XCTestCase {
    func testFullRangeReachesTheLastPixel() {
        let region = ScreenRegion(x: 0, y: 0, width: 1920, height: 1080)
        // Off by one here makes the screen edge — scrollbars, the close
        // button, the dock — permanently unclickable, which is invisible in
        // testing and infuriating in use.
        XCTAssertEqual(region.point(normalizedX: 1, normalizedY: 1).x, 1919)
        XCTAssertEqual(region.point(normalizedX: 1, normalizedY: 1).y, 1079)
        XCTAssertEqual(region.point(normalizedX: 0, normalizedY: 0).x, 0)
    }

    func testNegativeOriginIsHonoured() {
        // A monitor left of or above the primary gives the region a negative
        // origin on both Windows and X11-with-Xinerama.
        let region = ScreenRegion(x: -1920, y: -200, width: 1920, height: 1080)
        assertPoint(region.point(normalizedX: 0, normalizedY: 0), -1920, -200)
    }

    func testOutOfRangeClampsRatherThanEscapingTheRegion() {
        // A security boundary, not a convenience: this is what stops a hostile
        // viewer placing the sharer's pointer outside the region its user can
        // actually see.
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

    /// Swift tuples are not `Equatable`, so the pair has to be compared
    /// component-wise. A helper rather than two assertions per case, so a
    /// failure names the whole point instead of one axis.
    private func assertPoint(
        _ actual: (x: Int, y: Int), _ x: Int, _ y: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            [actual.x, actual.y], [x, y],
            "expected (\(x), \(y)), got (\(actual.x), \(actual.y))", file: file, line: line)
    }
}
