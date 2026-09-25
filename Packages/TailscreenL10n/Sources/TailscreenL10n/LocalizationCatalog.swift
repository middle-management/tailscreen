import Foundation

/// The loaded translation table, and the one-time work of finding it.
///
/// Deliberately NOT `Bundle.module` — its synthesized accessor `fatalError`s
/// when the resource bundle is missing, which would crash every string lookup
/// on a bad Linux/Windows packaging run instead of degrading to English. So
/// the bundle is located by hand here; not finding it just leaves `table`
/// empty, and every key resolves to itself (the English text).
/// `@unchecked Sendable`: the only stored property is the lock.
final class LocalizationCatalog: @unchecked Sendable {
    static let shared = LocalizationCatalog()

    /// SwiftPM names the bundle `<something>_<target>.<ext>`, where both
    /// `<something>` and the extension (`.bundle` Darwin, `.resources`
    /// elsewhere) vary — match on the stable target-name suffix and confirm
    /// by looking inside for `.lproj`s.
    static let bundleNameStem = "_TailscreenL10n"
    static let bundleExtensions = ["bundle", "resources"]
    /// The conventional Darwin name, for docs and tests.
    static let bundleDirectoryName = "TailscreenL10n\(bundleNameStem).bundle"
    static let catalogFileName = "Localizable.strings"
    /// The development language — the language the keys themselves are in, and
    /// so the one language that needs no table.
    static let developmentLanguage = "en"

    /// Points the lookup at a directory of `.lproj`s. Set by tests; also an
    /// escape hatch for unusual packaging layouts.
    static let bundlePathEnvironmentKey = "TAILSCREEN_L10N_BUNDLE"
    /// Forces a language regardless of the system's — `TAILSCREEN_LANG=sv`.
    static let languageEnvironmentKey = "TAILSCREEN_LANG"

    private struct State {
        var isLoaded = false
        var language = LocalizationCatalog.developmentLanguage
        var table: [String: String] = [:]
        /// Keyed by `normalizeSpecifiers`, so a `%@`/`%lld` mismatch between
        /// call site and catalog costs nothing.
        var normalized: [String: String] = [:]
    }

    private let lock = Guarded<State>(State())

    /// Look the key up and substitute its arguments. Only the format string
    /// leaves the lock — substitution is pure.
    func string(for key: LocalizationKey) -> String {
        // Absent key falls back to itself — the English text — so an
        // untranslated and an untranslatable string look the same, not a bug.
        let format = lock.withLock { state -> String in
            Self.ensureLoaded(&state)
            return state.table[key.format]
                ?? state.normalized[LocalizationFormat.normalizeSpecifiers(key.format)]
                ?? key.format
        }
        return LocalizationFormat.render(format, key.arguments)
    }

    /// The language actually in use, for diagnostics and tests.
    var activeLanguage: String {
        lock.withLock { state -> String in
            Self.ensureLoaded(&state)
            return state.language
        }
    }

    /// Resolve the catalog once, on first use; called under the lock so the
    /// file I/O happens on exactly one thread.
    private static func ensureLoaded(_ state: inout State) {
        guard !state.isLoaded else { return }
        let resolved = load()
        state.isLoaded = true
        state.language = resolved.language
        state.table = resolved.table
        state.normalized = Dictionary(
            resolved.table.map { (LocalizationFormat.normalizeSpecifiers($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Drop the cached table so the next lookup re-resolves. Test-only —
    /// nothing in the app changes language mid-run.
    func resetForTesting() {
        lock.withLock { $0 = State() }
    }

    // MARK: - Resolution

    private static func load() -> (language: String, table: [String: String]) {
        guard let root = resourceRoot() else {
            return (developmentLanguage, [:])
        }
        let available = availableLocalizations(in: root)
        guard let language = match(preferredLanguages(), against: available) else {
            return (developmentLanguage, [:])
        }
        // Development language needs no table — its values are its keys, so a
        // missing en.lproj can't make English worse.
        guard language != developmentLanguage else { return (developmentLanguage, [:]) }

        let url =
            root
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent(catalogFileName)
        guard let data = try? Data(contentsOf: url) else {
            return (developmentLanguage, [:])
        }
        return (language, StringsFile.parse(data: data))
    }

    /// The directory holding the `.lproj`s, or nil if it isn't anywhere we look.
    static func resourceRoot() -> URL? {
        for candidate in searchDirectories() {
            if containsLocalizations(candidate) { return candidate }
            if let bundle = resourceBundle(in: candidate) { return bundle }
        }
        return nil
    }

    /// The generated resource bundle inside `directory`, matched by target
    /// name and confirmed by looking inside — the mac app ships a sibling
    /// bundle that must not be mistaken for this one.
    private static func resourceBundle(in directory: URL) -> URL? {
        let bundles =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { bundleExtensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ours = bundles.filter {
            $0.deletingPathExtension().lastPathComponent.hasSuffix(bundleNameStem)
        }
        return (ours + bundles).first(where: containsLocalizations)
    }

    private static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        // An explicit override is the ONLY place looked at, not the first of
        // several — otherwise a wrong catalog could load silently.
        if let override = environment[bundlePathEnvironmentKey], !override.isEmpty {
            return [URL(fileURLWithPath: override)]
        }
        // macOS: Contents/Resources. Linux/Windows: the executable's own
        // directory, where staging scripts copy the resource bundle.
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        directories.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            directories.append(executable)
        }
        return directories
    }

    private static func containsLocalizations(_ directory: URL) -> Bool {
        !availableLocalizations(in: directory).isEmpty
    }

    /// Language tags of the `.lproj` directories present under `directory`.
    static func availableLocalizations(in directory: URL) -> [String] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return
            contents
            .filter { $0.pathExtension == "lproj" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: - Language preference

    /// The user's languages, most-preferred first, as BCP-47-ish tags. Order:
    /// explicit override, then Darwin's `Locale.preferredLanguages`, then the
    /// POSIX locale env vars a Linux GTK app runs under, then `Locale.current`
    /// for Windows' default UI language.
    static func preferredLanguages() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment[languageEnvironmentKey], !forced.isEmpty {
            return expand(forced.split(separator: ",").map(String.init))
        }
        #if canImport(Darwin)
        return expand(Locale.preferredLanguages)
        #else
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            let normalized = normalize(value)
            // "C" and "POSIX" mean "no locale", not "a locale called C".
            guard !normalized.isEmpty, normalized != "c", normalized != "posix" else { continue }
            return expand([value])
        }
        return expand([Locale.current.identifier])
        #endif
    }

    /// Each tag plus its progressively shorter prefixes, so `sv_SE.UTF-8`
    /// reaches an `sv.lproj`: ["sv-se", "sv"].
    private static func expand(_ tags: [String]) -> [String] {
        var out: [String] = []
        for tag in tags {
            var components = normalize(tag).split(separator: "-").map(String.init)
            while !components.isEmpty {
                let candidate = components.joined(separator: "-")
                if !candidate.isEmpty, !out.contains(candidate) { out.append(candidate) }
                components.removeLast()
            }
        }
        return out
    }

    /// `sv_SE.UTF-8` / `sv_SE@euro` / `sv-SE` → `sv-se`.
    static func normalize(_ tag: String) -> String {
        var value = tag
        if let cut = value.firstIndex(where: { $0 == "." || $0 == "@" }) {
            value = String(value[value.startIndex..<cut])
        }
        return value.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// First preferred tag with a matching `.lproj`, compared case- and
    /// separator-insensitively so an `en-GB.lproj` answers `en_GB.UTF-8`.
    static func match(_ preferred: [String], against available: [String]) -> String? {
        let byNormalizedName = Dictionary(
            available.map { (normalize($0), $0) }, uniquingKeysWith: { first, _ in first })
        for tag in preferred {
            if let hit = byNormalizedName[tag] { return hit }
        }
        return nil
    }
}
