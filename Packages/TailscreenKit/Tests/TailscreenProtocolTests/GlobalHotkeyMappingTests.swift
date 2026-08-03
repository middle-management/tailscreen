import XCTest

@testable import TailscreenProtocol

/// The `ShortcutCatalog` row → OS hotkey registration translation, and the
/// decision about which microphone a single chord flips.
///
/// Everything here is arithmetic over tables, which is the point: the two C
/// shims that consume it (`XGrabKey` on Linux, `RegisterHotKey` on Windows)
/// cannot be run by Linux CI and, on Windows, cannot be run by this repository
/// at all. What CI *can* prove is that the numbers handed to them are right —
/// and every failure mode below is silent in production: a wrong keysym is a
/// key that does nothing, a missing lock-mask variant is a hotkey that stops
/// working when Num Lock is on, a missing `MOD_NOREPEAT` is a mute whose final
/// state depends on how long a finger rested on a key.
final class GlobalHotkeyMappingTests: XCTestCase {

    // MARK: - ShortcutKey → HID

    func testLettersDigitsAndPunctuationMapToHID() {
        XCTAssertEqual(ShortcutKey.character("a").hidUsage, 0x04)
        XCTAssertEqual(ShortcutKey.character("m").hidUsage, 0x10)
        XCTAssertEqual(ShortcutKey.character("z").hidUsage, 0x1D)
        // The catalog stores "z" but displays "Z"; either spelling is the
        // same physical key and must map identically.
        XCTAssertEqual(ShortcutKey.character("M").hidUsage, 0x10)

        // HID orders the digits 1…9 then 0; ASCII puts 0 first. An off-by-one
        // here shifts every digit shortcut by one key.
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

    func testPlusIsRefusedRatherThanGuessed() {
        // The catalog spells zoom-in "⌘+" because that is what a person reads,
        // but no US keyboard has a `+` key — it is Shift and `=`. Mapping it to
        // `=` would register a global hotkey that fires on a keystroke the user
        // was never told about.
        XCTAssertNil(ShortcutKey.character("+").hidUsage)
        XCTAssertNil(ShortcutKey.character("").hidUsage)
        XCTAssertNil(ShortcutKey.character("F1").hidUsage)
    }

    // MARK: - X11

    func testMicChordGrabsControlAltM() {
        let chord = ShortcutChord(.character("m"), [.control, .option])
        let grab = X11HotkeyMapping.grab(for: chord)
        // XK_m — the LOWERCASE keysym, which is the one `XKeysymToKeycode`
        // resolves to the physical M key.
        XCTAssertEqual(grab?.keysym, 0x006D)
        XCTAssertEqual(
            grab?.modifierMask, X11HotkeyMapping.controlMask | X11HotkeyMapping.mod1Mask)
    }

    func testPrimaryFoldsOntoControlOffMacOS() {
        // `primary` is ⌘ on macOS and Ctrl everywhere else, so both spellings
        // must produce the same X11 mask — and naming the bit twice must set
        // it once, not twice.
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

    func testBareKeyIsRefused() {
        // `XGrabKey` would take it, and every other client on the display
        // would lose that key.
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

        // 2³ subsets of {Caps, Num, Scroll}, all distinct, all containing the
        // base. Anything less and the hotkey stops working the moment one of
        // those lock keys is on — with no error anywhere.
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
        // Without MOD_NOREPEAT a held chord flips the mute latch at the
        // keyboard's repeat rate, so whether the mic ends up on or off depends
        // on how long the key was held.
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

    func testEveryGlobalEntryIsRegistrableOnBothPlatforms() {
        // The catalog is what the UI advertises. A row flagged `isGlobal` that
        // neither platform can register is a shortcut printed in a cheat sheet
        // that will never fire.
        XCTAssertFalse(ShortcutCatalog.globals.isEmpty)
        for entry in ShortcutCatalog.globals {
            XCTAssertNotNil(
                X11HotkeyMapping.grab(for: entry.chord), "\(entry.command) is ungrabbable on X11")
            XCTAssertNotNil(
                WindowsHotkeyMapping.registration(for: entry.chord),
                "\(entry.command) is unregistrable on Win32")
        }
    }

    func testGlobalsAreDistinctChordsOnEveryPlatform() {
        // Two globals resolving to the same (keysym, mask) would mean the
        // second grab is refused by the first — a shortcut lost to a
        // collision the `.words` display style already warns about.
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
        // The reason is shown to a person; an empty or duplicated one is a
        // shortcut that stopped working with no usable explanation.
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
        // X11 auto-repeat, with detectable auto-repeat on: presses with no
        // release between them.
        XCTAssertFalse(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.release))
        XCTAssertTrue(filter.shouldFire(.press))
    }

    func testDeliberateFastDoubleTapBothFire() {
        // A latch, not a debounce, precisely so mute-glance-unmute works. A
        // time-based filter would swallow the second press.
        var filter = GlobalHotkeyRepeatFilter()
        XCTAssertTrue(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.release))
        XCTAssertTrue(filter.shouldFire(.press))
        XCTAssertFalse(filter.shouldFire(.release))
    }

    func testResetForgetsAHeldKey() {
        // A re-grab: the release that would have cleared the latch went to
        // whoever held the grab before us.
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
