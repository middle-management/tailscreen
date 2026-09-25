import XCTest

@testable import TailscreenL10n

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// End-to-end lookup: find a catalog on disk, pick a language, translate.
/// Driven through the two documented env vars, the same path a packager or
/// screenshot run uses (minus SwiftPM's generated resource bundle).
///
/// All env-mutating cases live in ONE class: they share the process
/// environment and the catalog's lazy cache.
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

    /// `sv_SE.UTF-8` (what a GTK app runs under) resolves to `sv`; there is no `sv-SE.lproj`.
    func testRegionalTagFallsBackToTheLanguage() {
        use(language: "sv_SE.UTF-8", bundle: directory)
        XCTAssertEqual(LocalizationCatalog.shared.activeLanguage, "sv")
        XCTAssertEqual(L("Refresh"), "Uppdatera")
    }

    func testUntranslatedKeyFallsBackToEnglish() {
        use(language: "sv", bundle: directory)
        XCTAssertEqual(L("Block"), "Block")
    }

    /// An unshipped language, and a bundle that isn't there at all — both
    /// must render in English, not abort (unlike `Bundle.module`).
    func testMissingLanguageOrBundleDegradesToEnglish() {
        use(language: "de", bundle: directory)
        XCTAssertEqual(LocalizationCatalog.shared.activeLanguage, "en")
        XCTAssertEqual(L("Refresh"), "Refresh")

        // Also pins that the override is the ONLY place looked at — otherwise
        // this could find the real shipped catalog next to the test binary.
        use(language: "sv", bundle: directory.appendingPathComponent("nowhere"))
        XCTAssertEqual(L("Refresh"), "Refresh")
        XCTAssertEqual(L("\(2) watching"), "2 watching")
    }

    /// A call-site type change (`%@` vs. the catalog's `%lld`) must not
    /// silently untranslate a string — the normalized index catches it.
    func testSpecifierDisagreementStillFindsTheTranslation() {
        use(language: "sv", bundle: directory)
        let key = LocalizationKey(format: "%@ watching", arguments: [.integer(2)])
        XCTAssertEqual(LocalizationCatalog.shared.string(for: key), "2 tittar")
    }

    /// The bundle path may name the generated bundle directory itself or its
    /// parent (staging scripts vs. a `swift build` tree). Named with a
    /// non-standard prefix and `.resources` (Linux extension) deliberately —
    /// SwiftPM's actual prefix isn't stable across toolchains, so the lookup
    /// must match on the suffix it owns, not the full name.
    func testFindsTheCatalogInsideAGeneratedResourceBundle() throws {
        let parent = directory.appendingPathComponent("staged")
        let bundle = parent.appendingPathComponent(
            "whatever-swiftpm-decided\(LocalizationCatalog.bundleNameStem).resources")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("sv.lproj"), withIntermediateDirectories: true)
        try #""Refresh" = "Uppdatera";"#.write(
            to: bundle.appendingPathComponent("sv.lproj/Localizable.strings"),
            atomically: true, encoding: .utf8)

        use(language: "sv", bundle: parent)
        XCTAssertEqual(L("Refresh"), "Uppdatera")
    }

    /// A sibling resource bundle (the mac app ships two) must not be mistaken
    /// for the catalog.
    func testIgnoresAnUnrelatedSiblingBundle() throws {
        let parent = directory.appendingPathComponent("staged")
        let decoy = parent.appendingPathComponent("Tailscreen_Tailscreen.bundle")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data().write(to: decoy.appendingPathComponent("MenubarIcon.pdf"))

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

    /// Preference order wins over specificity.
    func testFirstPreferredWins() {
        XCTAssertEqual(LocalizationCatalog.match(["sv", "en"], against: ["en", "sv"]), "sv")
        XCTAssertEqual(LocalizationCatalog.match(["en", "sv"], against: ["en", "sv"]), "en")
    }
}
