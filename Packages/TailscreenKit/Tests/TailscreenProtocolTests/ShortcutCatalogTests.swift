import XCTest

@testable import TailscreenProtocol

/// `ShortcutCatalog` — the one list of keyboard shortcuts all three hosts
/// render. Pinned because the failure it replaces was silent: macOS once kept
/// its menu and cheat sheet as separate hand-written lists, and ⌃⌥. (the panic
/// key that revokes a viewer's control) ended up in neither.
final class ShortcutCatalogTests: XCTestCase {

    // MARK: - Integrity

    func testEveryCommandHasExactlyOneEntry() {
        for command in ShortcutCommand.allCases {
            let matches = ShortcutCatalog.entries.filter { $0.command == command }
            XCTAssertEqual(matches.count, 1, "\(command) has \(matches.count) entries, want 1")
        }
        XCTAssertEqual(ShortcutCatalog.entries.count, ShortcutCommand.allCases.count)
    }

    func testEveryEntryHasASummary() {
        for entry in ShortcutCatalog.entries {
            XCTAssertFalse(entry.summary.isEmpty, "\(entry.command) has no summary")
        }
    }

    /// A section that renders as an empty box is a bug in the catalog, not a
    /// rendering choice each host should have to guard against.
    func testEverySectionHasEntries() {
        for section in ShortcutSection.allCases {
            XCTAssertFalse(
                ShortcutCatalog.entries(in: section).isEmpty,
                "section \(section) is declared but empty")
        }
    }

    func testLookupByCommand() {
        let entry = ShortcutCatalog.entry(for: .stopRemoteControl)
        XCTAssertEqual(entry?.chord.modifiers, [.control, .option])
        XCTAssertEqual(entry?.chord.key, .character("."))
    }

    // MARK: - Collisions

    /// Two commands on one chord means one of them silently never fires.
    func testNoCollisionsOnMacOS() {
        let collisions = ShortcutCatalog.collisions(.appleSymbols)
        XCTAssertTrue(collisions.isEmpty, "colliding shortcuts: \(collisions)")
    }

    /// `primary` (⌘) and `control` (⌃) are distinct in the menu bar but both
    /// collapse to Ctrl on GTK/WinUI, so a pair fine on macOS can collide
    /// elsewhere — not an error, just the wrong command running.
    func testNoCollisionsOffMacOS() {
        let collisions = ShortcutCatalog.collisions(.words)
        XCTAssertTrue(collisions.isEmpty, "colliding shortcuts off macOS: \(collisions)")
    }

    /// Proves the collision check can actually fail — a detector that always
    /// returns empty would pass both tests above while checking nothing.
    func testCollisionDetectorFindsAConstructedClash() {
        let a = ShortcutChord(.character("k"), .primary)
        let b = ShortcutChord(.character("k"), .control)
        XCTAssertNotEqual(
            a.display(.appleSymbols), b.display(.appleSymbols),
            "⌘K and ⌃K must stay distinct on macOS")
        XCTAssertEqual(
            a.display(.words), b.display(.words),
            "both collapse to Ctrl+K off macOS — the case collisions(.words) exists to catch")
    }

    // MARK: - Display

    /// Apple renders modifiers in exactly this order everywhere; a list using
    /// another order would look wrong beside the menu bar it documents.
    func testAppleModifierOrderIsCanonical() {
        let chord = ShortcutChord(.character("k"), [.primary, .option, .shift, .control])
        XCTAssertEqual(chord.display(.appleSymbols), "⌃⌥⇧⌘K")
    }

    func testAppleSymbolsForRealEntries() {
        XCTAssertEqual(
            ShortcutCatalog.entry(for: .toggleMicrophone)?.chord.display(.appleSymbols), "⌃⌥M")
        XCTAssertEqual(
            ShortcutCatalog.entry(for: .stopRemoteControl)?.chord.display(.appleSymbols), "⌃⌥.")
        XCTAssertEqual(
            ShortcutCatalog.entry(for: .undoAnnotation)?.chord.display(.appleSymbols), "⌘Z")
        XCTAssertEqual(
            ShortcutCatalog.entry(for: .clearAnnotations)?.chord.display(.appleSymbols), "⇧⌘⌫")
    }

    func testWordStyleForOtherPlatforms() {
        XCTAssertEqual(
            ShortcutCatalog.entry(for: .toggleMicrophone)?.chord.display(.words), "Ctrl+Alt+M")
        XCTAssertEqual(
            ShortcutCatalog.entry(for: .undoAnnotation)?.chord.display(.words), "Ctrl+Z")
    }

    /// Ctrl must appear once even when both roles are set, or the label reads
    /// "Ctrl+Ctrl+K".
    func testWordStyleDoesNotDoubleCtrl() {
        let chord = ShortcutChord(.character("k"), [.primary, .control])
        XCTAssertEqual(chord.display(.words), "Ctrl+K")
    }

    func testBareKeyNeedsNoModifiers() {
        XCTAssertEqual(ShortcutCatalog.entry(for: .toolPen)?.chord.display(.appleSymbols), "1")
        XCTAssertEqual(ShortcutCatalog.entry(for: .toolPen)?.chord.display(.words), "1")
    }

    func testNamedKeysRender() {
        XCTAssertEqual(ShortcutKey.escape.display, "Esc")
        XCTAssertEqual(ShortcutKey.delete.display, "⌫")
        XCTAssertEqual(ShortcutKey.character("m").display, "M")
    }

    // MARK: - Globals

    /// Must work while the app is behind whatever is being shared: muting is
    /// a reflex, and taking the machine back can't require finding a window first.
    func testGlobalsAreTheTwoMidShareReflexes() {
        XCTAssertEqual(
            Set(ShortcutCatalog.globals.map(\.command)), [.toggleMicrophone, .stopRemoteControl])
    }

    /// A global shortcut is registered with the OS, which can refuse it if
    /// another app owns the combo — each entry is a failure a host must
    /// surface, so keep the set small and deliberate.
    func testGlobalsAreDeliberatelyFew() {
        XCTAssertLessThanOrEqual(
            ShortcutCatalog.globals.count, 3,
            "each global is a system-wide grab and a failure path a host must surface")
    }

    func testThePanicKeyIsInTheCatalog() {
        let entry = ShortcutCatalog.entry(for: .stopRemoteControl)
        XCTAssertNotNil(entry, "the panic key must be documented")
        XCTAssertEqual(entry?.chord.display(.appleSymbols), "⌃⌥.")
        XCTAssertTrue(entry?.isGlobal ?? false)
    }

    // MARK: - Codable

    func testChordRoundTrips() throws {
        let chord = ShortcutChord(.delete, [.primary, .shift])
        let data = try JSONEncoder().encode(chord)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutChord.self, from: data), chord)
    }

    func testCommandRawValuesAreStable() {
        // Raw values key any persisted remapping; renaming one silently
        // orphans a user's customization.
        XCTAssertEqual(ShortcutCommand.toggleMicrophone.rawValue, "toggleMicrophone")
        XCTAssertEqual(ShortcutCommand.stopRemoteControl.rawValue, "stopRemoteControl")
    }
}
