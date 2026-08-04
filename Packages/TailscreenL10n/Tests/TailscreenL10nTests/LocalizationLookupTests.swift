import XCTest

@testable import TailscreenL10n

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// End-to-end lookup: find a catalog on disk, pick a language, translate.
///
/// Driven through the two environment variables the package documents rather
/// than through `Bundle.module`, which is also how a packager or a screenshot
/// run points the app at a catalog. That makes this test the same code path
/// the app takes on Linux and Windows, minus the resource bundle SwiftPM
/// generates.
///
/// All the env-mutating cases live in ONE class on purpose: they share the
/// process environment and the catalog's lazy cache, and splitting them across
/// classes would make the order they run in matter.
final class LocalizationLookupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        #if !canImport(Darwin) && !canImport(Glibc)
        throw XCTSkip("no setenv on this platform")
        #else
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscreen-l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sv.lproj"), withIntermediateDirectories: true)
        try """
            "Refresh" = "Uppdatera";
            "%lld watching" = "%lld tittar";
            "%@ wants to watch" = "%@ vill titta";
            """
            .write(
                to: directory.appendingPathComponent("sv.lproj/Localizable.strings"),
                atomically: true, encoding: .utf8)
        #endif
    }

    override func tearDown() {
        #if canImport(Darwin) || canImport(Glibc)
        _ = unsetenv(LocalizationCatalog.bundlePathEnvironmentKey)
        _ = unsetenv(LocalizationCatalog.languageEnvironmentKey)
        LocalizationCatalog.shared.resetForTesting()
        if let created = directory { try? FileManager.default.removeItem(at: created) }
        #endif
    }

    private func use(language: String?, bundle: URL?) {
        #if canImport(Darwin) || canImport(Glibc)
        if let bundle {
            _ = setenv(LocalizationCatalog.bundlePathEnvironmentKey, bundle.path, 1)
        } else {
            _ = unsetenv(LocalizationCatalog.bundlePathEnvironmentKey)
        }
        if let language {
            _ = setenv(LocalizationCatalog.languageEnvironmentKey, language, 1)
        } else {
            _ = unsetenv(LocalizationCatalog.languageEnvironmentKey)
        }
        LocalizationCatalog.shared.resetForTesting()
        #endif
    }

    func testTranslatesAndInterpolates() {
        use(language: "sv", bundle: directory)
        XCTAssertEqual(LocalizationCatalog.shared.activeLanguage, "sv")
        XCTAssertEqual(L("Refresh"), "Uppdatera")
        XCTAssertEqual(L("\(2) watching"), "2 tittar")
        XCTAssertEqual(L("\("wisp") wants to watch"), "wisp vill titta")
    }

    /// A regional tag resolves to the language catalog: `sv_SE.UTF-8` is what
    /// a GTK app actually runs under, and there is no `sv-SE.lproj`.
    func testRegionalTagFallsBackToTheLanguage() {
        use(language: "sv_SE.UTF-8", bundle: directory)
        XCTAssertEqual(LocalizationCatalog.shared.activeLanguage, "sv")
        XCTAssertEqual(L("Refresh"), "Uppdatera")
    }

    /// A key the translation does not carry is not an error — the key IS the
    /// English text.
    func testUntranslatedKeyFallsBackToEnglish() {
        use(language: "sv", bundle: directory)
        XCTAssertEqual(L("Block"), "Block")
    }

    /// An unshipped language, and a bundle that is not there at all. Both are
    /// ordinary outcomes: an app whose resource bundle failed to ship must
    /// render in English, not abort — which is exactly what `Bundle.module`
    /// would have done here.
    func testMissingLanguageOrBundleDegradesToEnglish() {
        use(language: "de", bundle: directory)
        XCTAssertEqual(LocalizationCatalog.shared.activeLanguage, "en")
        XCTAssertEqual(L("Refresh"), "Refresh")

        // A named-but-absent bundle is the packaging accident this whole
        // fallback exists for. It also pins that the override is the ONLY
        // place looked at: `.build/debug` next to this test binary really does
        // hold the shipped catalog, and finding *that* instead would make the
        // assertion below pass in Swedish.
        use(language: "sv", bundle: directory.appendingPathComponent("nowhere"))
        XCTAssertEqual(L("Refresh"), "Refresh")
        XCTAssertEqual(L("\(2) watching"), "2 watching")
    }

    /// The catalog says `%lld watching`; a call site that interpolated
    /// something non-`Int` would build `%@ watching`. The normalized index
    /// makes those the same lookup, so a type change at a call site cannot
    /// silently untranslate a string.
    func testSpecifierDisagreementStillFindsTheTranslation() {
        use(language: "sv", bundle: directory)
        let key = LocalizationKey(format: "%@ watching", arguments: [.integer(2)])
        XCTAssertEqual(LocalizationCatalog.shared.string(for: key), "2 tittar")
    }

    /// The bundle path may name the generated `…_TailscreenL10n.bundle`
    /// directory itself or the directory holding it — the staging scripts
    /// produce the second shape and a `swift build` tree the first.
    func testFindsTheCatalogInsideAGeneratedResourceBundle() throws {
        let parent = directory.appendingPathComponent("staged")
        let bundle = parent.appendingPathComponent(LocalizationCatalog.bundleDirectoryName)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("sv.lproj"), withIntermediateDirectories: true)
        try #""Refresh" = "Uppdatera";"#.write(
            to: bundle.appendingPathComponent("sv.lproj/Localizable.strings"),
            atomically: true, encoding: .utf8)

        use(language: "sv", bundle: parent)
        XCTAssertEqual(L("Refresh"), "Uppdatera")
    }
}

/// The language-preference arithmetic, with no environment involved.
final class LocalizationLanguageMatchTests: XCTestCase {
    func testNormalizeStripsEncodingAndModifier() {
        XCTAssertEqual(LocalizationCatalog.normalize("sv_SE.UTF-8"), "sv-se")
        XCTAssertEqual(LocalizationCatalog.normalize("de_DE@euro"), "de-de")
        XCTAssertEqual(LocalizationCatalog.normalize("en-GB"), "en-gb")
        XCTAssertEqual(LocalizationCatalog.normalize("sv"), "sv")
    }

    func testMatchIsCaseAndSeparatorInsensitive() {
        XCTAssertEqual(LocalizationCatalog.match(["en-gb", "en"], against: ["en", "sv"]), "en")
        XCTAssertEqual(
            LocalizationCatalog.match(["pt-br"], against: ["en", "pt-BR"]), "pt-BR")
        XCTAssertNil(LocalizationCatalog.match(["de"], against: ["en", "sv"]))
    }

    /// Preference order wins over specificity: a user who asks for Swedish
    /// first and English second gets Swedish even though both are shipped.
    func testFirstPreferredWins() {
        XCTAssertEqual(LocalizationCatalog.match(["sv", "en"], against: ["en", "sv"]), "sv")
        XCTAssertEqual(LocalizationCatalog.match(["en", "sv"], against: ["en", "sv"]), "en")
    }
}
