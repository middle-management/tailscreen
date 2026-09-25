import XCTest

@testable import TailscreenProtocol

/// The `ShortcutCatalog` row → OS hotkey registration translation. The C
/// shims that consume it (`XGrabKey`, `RegisterHotKey`) can't run under CI,
/// but CI can prove the numbers handed to them are right — every failure
/// mode below is silent in production: a wrong keysym does nothing, a
/// missing lock-mask variant breaks with Num Lock on, a missing
/// `MOD_NOREPEAT` makes mute state depend on how long a key was held.
final class GlobalHotkeyMappingTests: XCTestCase {

    // MARK: - ShortcutKey → HID

    func testLettersDigitsAndPunctuationMapToHID() {
        XCTAssertEqual(ShortcutKey.character("a").hidUsage, 0x04)
        XCTAssertEqual(ShortcutKey.character("m").hidUsage, 0x10)
        XCTAssertEqual(ShortcutKey.character("z").hidUsage, 0x1D)
        XCTAssertEqual(ShortcutKey.character("M").hidUsage, 0x10)

        // HID orders digits 1…9 then 0; ASCII puts 0 first.
        XCTAssertEqual(ShortcutKey.character("1").hidUsage, 0x1E)
        XCTAssertEqual(ShortcutKey.character("9").hidUsage, 0x26)
        XCTAssertEqual(ShortcutKey.character("0").hidUsage, 0x27)

        XCTAssertEqual(ShortcutKey.character(".").hidUsage, 0x37)
        XCTAssertEqual(ShortcutKey.character("-").hidUsage, 0x2D)
        XCTAssertEqual(ShortcutKey.character("/").hidUsage, 0x38)
        XCTAssertEqual(ShortcutKey.escape.hidUsage, 0x29)
        // ⌫ is Backspace (0x2A), not forward Delete (0x4C).
        XCTAssertEqual(ShortcutKey.delete.hidUsage, 0x2A)
    }

    /// No US keyboard has a `+` key (it's Shift and `=`); mapping it to `=`
    /// would fire on a keystroke the user was never told about.
    func testPlusIsRefusedRatherThanGuessed() {
        XCTAssertNil(ShortcutKey.character("+").hidUsage)
        XCTAssertNil(ShortcutKey.character("").hidUsage)
        XCTAssertNil(ShortcutKey.character("F1").hidUsage)
    }

    // MARK: - X11

    func testMicChordGrabsControlAltM() {
        let chord = ShortcutChord(.character("m"), [.control, .option])
        let grab = X11HotkeyMapping.grab(for: chord)
        XCTAssertEqual(grab?.keysym, 0x006D)  // XK_m, lowercase
        XCTAssertEqual(
            grab?.modifierMask, X11HotkeyMapping.controlMask | X11HotkeyMapping.mod1Mask)
    }

    /// Naming the bit twice must set it once, not twice.
    func testPrimaryFoldsOntoControlOffMacOS() {
        let viaControl = X11HotkeyMapping.modifierMask([.control, .option])
        let viaPrimary = X11HotkeyMapping.modifierMask([.primary, .option])
        let viaBoth = X11HotkeyMapping.modifierMask([.primary, .control, .option])
        XCTAssertEqual(viaControl, viaPrimary)
        XCTAssertEqual(viaControl, viaBoth)
    }

    func testShiftIsCarriedIntoTheMask() {
        let mask = X11HotkeyMapping.modifierMask([.primary, .shift])
        XCTAssertEqual(mask, X11HotkeyMapping.controlMask | X11HotkeyMapping.shiftMask)
    }

    /// `XGrabKey` would take it, and every other client on the display
    /// would lose that key.
    func testBareKeyIsRefused() {
        XCTAssertNil(X11HotkeyMapping.grab(for: ShortcutChord(.character("m"))))
        XCTAssertNil(WindowsHotkeyMapping.registration(for: ShortcutChord(.character("m"))))
    }

    func testUnmappableKeyIsRefused() {
        let chord = ShortcutChord(.character("+"), [.primary, .option])
        XCTAssertNil(X11HotkeyMapping.grab(for: chord))
        XCTAssertNil(WindowsHotkeyMapping.registration(for: chord))
    }

    func testGrabMasksCoverEveryLockCombination() {
        let base = X11HotkeyMapping.controlMask | X11HotkeyMapping.mod1Mask
        let masks = X11HotkeyMapping.grabMasks(base: base)

        // 2³ subsets of {Caps, Num, Scroll} — anything less and the hotkey
        // stops working when one of those lock keys is on.
        XCTAssertEqual(masks.count, 8)
        XCTAssertEqual(Set(masks).count, 8)
        for mask in masks {
            XCTAssertEqual(mask & base, base, "0x\(String(mask, radix: 16)) dropped a base bit")
        }
        XCTAssertEqual(masks.first, base, "the plain mask must be grabbed too")
        XCTAssertTrue(masks.contains(base | X11HotkeyMapping.lockMask))
        XCTAssertTrue(masks.contains(base | X11HotkeyMapping.mod2Mask))
        XCTAssertTrue(masks.contains(base | X11HotkeyMapping.mod5Mask))
        XCTAssertTrue(
            masks.contains(
                base | X11HotkeyMapping.lockMask | X11HotkeyMapping.mod2Mask
                    | X11HotkeyMapping.mod5Mask))
    }

    // MARK: - Windows

    func testMicChordRegistersAsControlAltM() {
        let chord = ShortcutChord(.character("m"), [.control, .option])
        let registration = WindowsHotkeyMapping.registration(for: chord)
        XCTAssertEqual(registration?.virtualKey, 0x4D)  // VK 'M'
        XCTAssertEqual(
            registration?.modifiers,
            WindowsHotkeyMapping.modNoRepeat | WindowsHotkeyMapping.modControl
                | WindowsHotkeyMapping.modAlt)
    }

    func testEveryRegistrationCarriesNoRepeat() {
        for entry in ShortcutCatalog.globals {
            guard let registration = WindowsHotkeyMapping.registration(for: entry.chord) else {
                continue
            }
            XCTAssertEqual(
                registration.modifiers & WindowsHotkeyMapping.modNoRepeat,
                WindowsHotkeyMapping.modNoRepeat,
                "\(entry.command) would auto-repeat")
        }
    }

    func testRevokeChordMapsToTheOemPeriodKey() {
        let chord = ShortcutChord(.character("."), [.control, .option])
        XCTAssertEqual(WindowsHotkeyMapping.registration(for: chord)?.virtualKey, 0xBE)
        XCTAssertEqual(X11HotkeyMapping.grab(for: chord)?.keysym, 0x002E)  // XK_period
    }

    // MARK: - The catalog's own globals

    /// A row flagged `isGlobal` that neither platform can register is a
    /// shortcut printed in a cheat sheet that will never fire.
    func testEveryGlobalEntryIsRegistrableOnBothPlatforms() {
        XCTAssertFalse(ShortcutCatalog.globals.isEmpty)
        for entry in ShortcutCatalog.globals {
            XCTAssertNotNil(
                X11HotkeyMapping.grab(for: entry.chord), "\(entry.command) is ungrabbable on X11")
            XCTAssertNotNil(
                WindowsHotkeyMapping.registration(for: entry.chord),
                "\(entry.command) is unregistrable on Win32")
        }
    }

    /// Two globals resolving to the same (keysym, mask) would mean the
    /// second grab is refused by the first.
    func testGlobalsAreDistinctChordsOnEveryPlatform() {
        let grabs = ShortcutCatalog.globals.compactMap { X11HotkeyMapping.grab(for: $0.chord) }
        XCTAssertEqual(Set(grabs.map { "\($0.keysym):\($0.modifierMask)" }).count, grabs.count)
        let registrations = ShortcutCatalog.globals.compactMap {
            WindowsHotkeyMapping.registration(for: $0.chord)
        }
        XCTAssertEqual(
            Set(registrations.map { "\($0.virtualKey):\($0.modifiers)" }).count,
            registrations.count)
    }

    // MARK: - Saying why not

    func testEveryUnavailabilityExplainsItselfDistinctly() {
        let all: [GlobalHotkeyUnavailability] = [
            .noDisplay, .waylandSession, .unmappableChord, .alreadyOwned, .unsupportedPlatform
        ]
        XCTAssertEqual(Set(all.map(\.reason)).count, all.count)
        for reason in all { XCTAssertFalse(reason.reason.isEmpty) }
    }

    // MARK: - Repeat filter

    func testHeldKeyFiresOnce() {
        var filter = GlobalHotkeyRepeatFilter()
        XCTAssertTrue(filter.shouldFire(.press))
        // X11 auto-repeat: presses with no release between them.
        XCTAssertFalse(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.release))
        XCTAssertTrue(filter.shouldFire(.press))
    }

    /// A latch, not a debounce — a time-based filter would swallow the
    /// second press.
    func testDeliberateFastDoubleTapBothFire() {
        var filter = GlobalHotkeyRepeatFilter()
        XCTAssertTrue(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.release))
        XCTAssertTrue(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.release))
    }

    func testResetForgetsAHeldKey() {
        var filter = GlobalHotkeyRepeatFilter()
        XCTAssertTrue(filter.shouldFire(.press))
        filter.reset()
        XCTAssertTrue(filter.shouldFire(.press))
    }

    func testReleaseAloneNeverFires() {
        var filter = GlobalHotkeyRepeatFilter()
        XCTAssertFalse(filter.shouldFire(.release))
        XCTAssertFalse(filter.shouldFire(.release))
    }
}
