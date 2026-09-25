import XCTest

@testable import TailscreenL10n

/// The half of localization that used to be Apple Foundation's job: parsing
/// `.strings`, choosing a language, substituting interpolated values. Runs on
/// Linux — the GTK/WinUI apps' strings are resolved by this code alone.
final class StringsFileTests: XCTestCase {
    func testParsesEntriesCommentsAndEscapes() {
        let table = StringsFile.parse(
            text: """
                /* A block comment, with "quotes" and a ; inside it. */
                "Simple" = "Enkel";
                // A line comment.
                "With \\"quotes\\"" = "Med \\"citat\\"";
                "Multi\\nline" = "Flera\\nrader";
                "Padded"    =    "Vadderad"  ;
                """)

        XCTAssertEqual(table["Simple"], "Enkel")
        XCTAssertEqual(table["With \"quotes\""], "Med \"citat\"")
        XCTAssertEqual(table["Multi\nline"], "Flera\nrader")
        XCTAssertEqual(table["Padded"], "Vadderad")
        XCTAssertEqual(table.count, 4)
    }

    /// One bad line costs one string, not the whole file.
    func testRecoversFromAMalformedEntry() {
        let table = StringsFile.parse(
            text: """
                "Before" = "Före";
                "Broken" = ;
                "After" = "Efter";
                """)

        XCTAssertEqual(table["Before"], "Före")
        XCTAssertEqual(table["After"], "Efter")
        XCTAssertNil(table["Broken"])
    }

    func testUnicodeEscapesAndEmptyInput() {
        XCTAssertEqual(StringsFile.parse(text: #""K" = "\U00e5ngstr\U00f6m";"#)["K"], "ångström")
        XCTAssertTrue(StringsFile.parse(text: "").isEmpty)
        XCTAssertTrue(StringsFile.parse(text: "/* only a comment */").isEmpty)
    }
}

final class LocalizationFormatTests: XCTestCase {
    func testSubstitutesInOrder() {
        XCTAssertEqual(
            LocalizationFormat.render("Viewing %@", [.text("wisp")]), "Viewing wisp")
        XCTAssertEqual(
            LocalizationFormat.render("%lld viewers connected", [.integer(3)]),
            "3 viewers connected")
        XCTAssertEqual(
            LocalizationFormat.render("%lld ms (%@)", [.integer(42), .text("good")]),
            "42 ms (good)")
    }

    /// A translation must be able to reorder the values (positional specifiers).
    func testHonorsPositionalSpecifiers() {
        XCTAssertEqual(
            LocalizationFormat.render("%2$@ har %1$lld tittare", [.integer(2), .text("wisp")]),
            "wisp har 2 tittare")
    }

    /// The conversion character says which slot, never how to read memory —
    /// a translator's `%d` where the key says `%@` renders, doesn't crash.
    func testConversionCharacterDoesNotSelectTheType() {
        XCTAssertEqual(LocalizationFormat.render("%d", [.text("wisp")]), "wisp")
        XCTAssertEqual(LocalizationFormat.render("%@", [.integer(7)]), "7")
    }

    /// "Zoom to 50%" is a real key — a bare `%` is literal text.
    func testLiteralPercentSurvives() {
        XCTAssertEqual(LocalizationFormat.render("Zoom to 50%", []), "Zoom to 50%")
        XCTAssertEqual(
            LocalizationFormat.render("%@ at 50%", [.text("wisp")]), "wisp at 50%")
        XCTAssertEqual(LocalizationFormat.render("100%% sure %@", [.text("x")]), "100% sure x")
    }

    /// More specifiers than arguments leaves the specifier visible rather
    /// than silently dropping the word.
    func testSurplusSpecifierIsLeftVisible() {
        XCTAssertEqual(LocalizationFormat.render("%@ and %@", [.text("a")]), "a and %@")
    }

    func testNormalizeCollapsesEverySpecifierForm() {
        XCTAssertEqual(
            LocalizationFormat.normalizeSpecifiers("%lld ms (%@)"),
            "\(LocalizationFormat.specifierPlaceholder) ms "
                + "(\(LocalizationFormat.specifierPlaceholder))")
        XCTAssertEqual(
            LocalizationFormat.normalizeSpecifiers("%1$@ %2$lld"),
            "\(LocalizationFormat.specifierPlaceholder) "
                + "\(LocalizationFormat.specifierPlaceholder)")
        XCTAssertEqual(LocalizationFormat.normalizeSpecifiers("Zoom to 50%"), "Zoom to 50%")
    }
}

final class LocalizationKeyTests: XCTestCase {
    func testInterpolationProducesTheCatalogKey() {
        let host = "wisp"
        let count = 3
        XCTAssertEqual(L10nProbe.key("Viewing \(host)").format, "Viewing %@")
        XCTAssertEqual(L10nProbe.key("\(count) viewers connected").format, "%lld viewers connected")
        XCTAssertEqual(L10nProbe.key("plain").format, "plain")
    }

    /// `Int` keeps `%lld` — the catalog was written against
    /// `String.LocalizationValue` and its keys weren't rewritten.
    func testIntKeepsItsOwnSpecifier() {
        XCTAssertEqual(L10nProbe.key("\(1) of \("two")").format, "%lld of %@")
    }

    /// Interpolating a bare `any Error` compiles and renders (several call
    /// sites do this; `Error` conforms to nothing a constrained overload could use).
    func testArbitraryValuesInterpolate() {
        struct Failure: Error {}
        let error: any Error = Failure()
        let key = L10nProbe.key("could not start sharing: \(error)")
        XCTAssertEqual(key.format, "could not start sharing: %@")
        XCTAssertEqual(
            LocalizationFormat.render(key.format, key.arguments),
            "could not start sharing: Failure()")
    }
}

/// Test-only shim: `L(_:)` returns the resolved string, so the key it built
/// is otherwise unobservable.
enum L10nProbe {
    static func key(_ key: LocalizationKey) -> LocalizationKey { key }
}
