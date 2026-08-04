import Foundation
import Synchronization

/// The loaded translation table, and the one-time work of finding it.
///
/// Deliberately NOT `Bundle.module`. The accessor SwiftPM synthesizes for that
/// property calls `fatalError` when the resource bundle is not beside the
/// executable — acceptable for an app whose icons live there, fatal for a
/// string lookup that every label on every screen goes through. A Linux
/// tarball or an MSIX that shipped without the bundle would abort on launch
/// instead of rendering in English. So the bundle is located here, by hand, and
/// not finding it is an ordinary outcome: `table` stays empty and every key
/// resolves to itself, which is the English string.
/// `@unchecked Sendable`: the only stored property is the lock, and the table
/// lives inside it — the same ownership pattern `RetransmitBuffer` uses.
final class LocalizationCatalog: @unchecked Sendable {
    static let shared = LocalizationCatalog()

    /// The half of SwiftPM's generated bundle name we actually own.
    ///
    /// It names bundles `<something>_<target>.bundle`, and the `<something>`
    /// is derived from the package in a way that has not been stable across
    /// toolchains — assuming `TailscreenL10n_TailscreenL10n.bundle` is what
    /// broke the first Linux packaging run. Matching the suffix, and then
    /// falling back to *any* `.bundle` that actually holds `.lproj`s, means
    /// being right about the catalog rather than about the name.
    static let bundleNameSuffix = "_TailscreenL10n.bundle"
    /// The conventional full name, for docs and tests.
    static let bundleDirectoryName = "TailscreenL10n\(bundleNameSuffix)"
    static let catalogFileName = "Localizable.strings"
    /// The development language — the language the keys themselves are in, and
    /// so the one language that needs no table.
    static let developmentLanguage = "en"

    /// Point the lookup at a directory of `.lproj`s (or at a
    /// `…_TailscreenL10n.bundle`). Set by tests; also a legitimate escape
    /// hatch for a packager whose layout puts the catalog somewhere unusual.
    static let bundlePathEnvironmentKey = "TAILSCREEN_L10N_BUNDLE"
    /// Force a language regardless of the system's — `TAILSCREEN_LANG=sv`.
    /// Screenshot tooling and manual verification both need this, and it is
    /// the only way to see another language on a host whose locale machinery
    /// reports nothing useful.
    static let languageEnvironmentKey = "TAILSCREEN_LANG"

    private struct State {
        var isLoaded = false
        var language = LocalizationCatalog.developmentLanguage
        var table: [String: String] = [:]
        /// The same table keyed by `normalizeSpecifiers`, so a `%@`/`%lld`
        /// disagreement between call site and catalog costs nothing.
        var normalized: [String: String] = [:]
    }

    private let lock = Mutex<State>(State())

    /// Look the key up and substitute its arguments.
    ///
    /// Only the format string leaves the lock — the substitution itself is
    /// pure and doesn't need it, and keeping the table inside means no caller
    /// can hold a copy of it.
    func string(for key: LocalizationKey) -> String {
        // A key absent from the table falls back to itself, which IS the
        // English text — so an untranslated string and an untranslatable one
        // look the same to the user, and neither looks like a bug.
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

    /// Resolve the catalog once, on first use. Called under the lock, so the
    /// file I/O happens on exactly one thread and every later caller finds the
    /// table already there.
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

    /// Drop the cached table so the next lookup re-resolves the environment.
    /// Test-only seam — nothing in the app changes language mid-run.
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
        // The development language needs no table: its values are its keys.
        // Skipping it is not just an optimization — it means an `en.lproj`
        // that failed to ship cannot make English worse than it already is.
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

    /// The directory holding the `.lproj`s, or nil if it isn't anywhere we
    /// look.
    static func resourceRoot() -> URL? {
        for candidate in searchDirectories() {
            // The directory itself, for a layout that drops the `.lproj`s
            // straight beside the binary.
            if containsLocalizations(candidate) { return candidate }
            if let bundle = resourceBundle(in: candidate) { return bundle }
        }
        return nil
    }

    /// The generated resource bundle inside `directory`, found by suffix
    /// rather than by full name — and confirmed by looking inside it, so a
    /// sibling bundle (the mac app ships two) can't be mistaken for this one.
    private static func resourceBundle(in directory: URL) -> URL? {
        let bundles =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bundle" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ours = bundles.filter { $0.lastPathComponent.hasSuffix(bundleNameSuffix) }
        return (ours + bundles).first(where: containsLocalizations)
    }

    private static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        // An explicit override is the ONLY place looked at, not the first of
        // several. Somebody who names a directory and gets the catalog from a
        // different one has been lied to — and the failure would be invisible,
        // since both answers are plausible strings on screen.
        if let override = environment[bundlePathEnvironmentKey], !override.isEmpty {
            return [URL(fileURLWithPath: override)]
        }
        // macOS: the app bundle's Contents/Resources, where the `.app`
        // assembly step drops every SwiftPM resource bundle.
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        // Linux/Windows: a bare executable's `bundleURL` is the directory it
        // sits in, which is also where SwiftPM leaves the resource bundle and
        // where both staging scripts copy it.
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

    /// The user's languages, most-preferred first, as BCP-47-ish tags.
    ///
    /// Three sources, in order, because the three platforms answer this
    /// question in three different places and only Darwin answers it well:
    /// an explicit override, then Darwin's `Locale.preferredLanguages` (the
    /// ordered list from System Settings), then the POSIX locale environment
    /// that a GTK app on Linux actually runs under — falling back to
    /// `Locale.current`, which is where a Windows process picks up the user's
    /// default UI language.
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

    /// Turn each tag into itself plus its progressively shorter prefixes, so
    /// `sv_SE.UTF-8` reaches an `sv.lproj`: ["sv-se", "sv"].
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
