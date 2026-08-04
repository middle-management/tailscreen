import XCTest

@testable import TailscreenL10n

/// The half of localization that used to be Apple Foundation's job: parsing a
/// `.strings` file, choosing a language, and putting the interpolated values
/// back into a translated sentence.
///
/// All of it runs on Linux, which is the point — the GTK and WinUI apps'
/// strings are resolved by this code and by nothing else, and before the
/// catalog was shared there was no machine that could check that.
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

    /// One bad line costs one string, not the language. A catalog is a
    /// translator deliverable and arrives imperfect; refusing the whole file
    /// would turn a typo into an untranslated app.
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

    /// A translation must be able to reorder the values — for several
    /// languages that is the only way to write a grammatical sentence.
    func testHonorsPositionalSpecifiers() {
        XCTAssertEqual(
            LocalizationFormat.render("%2$@ har %1$lld tittare", [.integer(2), .text("wisp")]),
            "wisp har 2 tittare")
    }

    /// The conversion character says which slot, never how to read memory:
    /// a translator who types `%d` where the key says `%@` gets a rendered
    /// word, not a crash.
    func testConversionCharacterDoesNotSelectTheType() {
        XCTAssertEqual(LocalizationFormat.render("%d", [.text("wisp")]), "wisp")
        XCTAssertEqual(LocalizationFormat.render("%@", [.integer(7)]), "7")
    }

    /// "Zoom to 50%" is a real key. A bare `%` that introduces nothing is
    /// literal text, and with no arguments the format is returned untouched.
    func testLiteralPercentSurvives() {
        XCTAssertEqual(LocalizationFormat.render("Zoom to 50%", []), "Zoom to 50%")
        XCTAssertEqual(
            LocalizationFormat.render("%@ at 50%", [.text("wisp")]), "wisp at 50%")
        XCTAssertEqual(LocalizationFormat.render("100%% sure %@", [.text("x")]), "100% sure x")
    }

    /// More specifiers than arguments leaves the specifier visible rather than
    /// dropping the word around it — a mistranslation you can see beats one
    /// you cannot.
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

    /// `Int` has to keep taking `%lld` — the catalog was written against
    /// `String.LocalizationValue`, which spelled it that way, and the keys were
    /// not rewritten when the lookup moved off it.
    func testIntKeepsItsOwnSpecifier() {
        XCTAssertEqual(L10nProbe.key("\(1) of \("two")").format, "%lld of %@")
    }

    /// Interpolating a bare `any Error` compiles and renders. Several call
    /// sites do it, and `Error` conforms to nothing that would let a
    /// constrained overload accept it.
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

/// Test-only shim: `L(_:)` returns the resolved string, so the KEY it built —
/// the thing the catalog is indexed by — is otherwise unobservable.
enum L10nProbe {
    static func key(_ key: LocalizationKey) -> LocalizationKey { key }
}
