import Foundation

/// One veiled app. Keyed by bundle ID — the identifier the capture-helper
/// resolves against `SCShareableContent.applications`, stable across
/// launches and app updates. `displayName` is cosmetic (shown in Settings)
/// and refreshed if the user re-adds the app under a new name.
public struct VeiledAppEntry: Codable, Sendable, Identifiable, Equatable {
    public let bundleID: String
    public var displayName: String
    public let addedAt: Date

    public var id: String { bundleID }

    public init(bundleID: String, displayName: String, addedAt: Date) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.addedAt = addedAt
    }
}

/// Persistent App Veil list backing the Settings "App Veil" section: apps
/// whose windows are hidden from viewers whenever a whole display is
/// shared, so the user never has to "clean up" their screen before
/// sharing. The list feeds `PickerSelection.excludedBundleIDs` via
/// `AppVeil.effectiveExclusions`.
///
/// `@MainActor` because it's UI-owned state (AppState holds it, SwiftUI
/// renders it) — same ownership model as `ViewerAccessPolicyStore`. The
/// screen-share server / capture-helper never touch this store; they see a
/// value snapshot baked into the selection JSON at share start (and on
/// each veil-list change while a display share is live).
///
/// Persistence is a JSON blob (the entries) plus a Bool (the master
/// toggle) under two `UserDefaults` keys. The defaults instance is
/// injectable so tests can use a scratch suite. The toggle defaults **on**
/// (a veil list you built should protect you without a second switch);
/// the tri-state read keeps an explicit opt-out sticky.
@MainActor
public final class AppVeilStore: ObservableObject {
    public static let entriesKey = "appVeilEntries"
    public static let enabledKey = "appVeilEnabled"

    /// All veiled apps, oldest first (stable Settings ordering).
    @Published private(set) public var entries: [VeiledAppEntry] = []

    /// Master toggle: when off, the list is kept but no apps are veiled —
    /// Tuple-style "temporarily unveil" without losing the list.
    @Published public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
        self.isEnabled = (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    /// Veil an app (or refresh its display name if already veiled).
    public func add(bundleID: String, displayName: String) {
        if let idx = entries.firstIndex(where: { $0.bundleID == bundleID }) {
            guard entries[idx].displayName != displayName else { return }
            entries[idx].displayName = displayName
        } else {
            entries.append(
                VeiledAppEntry(bundleID: bundleID, displayName: displayName, addedAt: Date()))
        }
        persist()
    }

    /// Unveil an app. No-op for unknown bundle IDs.
    public func remove(bundleID: String) {
        entries.removeAll { $0.bundleID == bundleID }
        persist()
    }

    public func isVeiled(_ bundleID: String) -> Bool {
        entries.contains { $0.bundleID == bundleID }
    }

    /// The bundle IDs to exclude from the current selection kind — the
    /// value snapshot AppState bakes into `PickerSelection.excludedBundleIDs`.
    public func effectiveExclusions(for kind: PickerSelection.Kind) -> [String] {
        AppVeil.effectiveExclusions(
            kind: kind, veiled: entries.map(\.bundleID), enabled: isEnabled)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }

    private static func load(from defaults: UserDefaults) -> [VeiledAppEntry] {
        guard let data = defaults.data(forKey: entriesKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([VeiledAppEntry].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Pure App Veil decision logic, extracted for CI-able tests
/// (`AppVeilTests`) — the store above is the stateful wrapper.
public enum AppVeil {
    /// Which bundle IDs a share of `kind` should exclude. Only `.display`
    /// shares veil: a `.window` share captures exactly one window, and an
    /// `.application` share's include-list already hides every app the
    /// user didn't pick — and an app the user *explicitly picked* to share
    /// wins over its veil entry (a deliberate choice beats a standing
    /// default). Order-stable dedupe so the encoded JSON is deterministic.
    public static func effectiveExclusions(
        kind: PickerSelection.Kind, veiled: [String], enabled: Bool
    ) -> [String] {
        guard enabled, kind == .display else { return [] }
        var seen = Set<String>()
        return veiled.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
