import Foundation

/// The viewer-side peer-list filter: which discovered Tailscreen peers the
/// menubar's AVAILABLE SCREENS section actually shows. Two axes, both
/// derived from netmap data the discovery layer already carries (no probes,
/// no wire change):
///
///  - **Status** — `hideOffline` drops rows tsnet reports unreachable.
///  - **Tags** — `selectedTags` keeps only peers carrying at least one of
///    the selected Tailscale ACL tags (`"tag:server"` etc.). Tags exist
///    only on *tagged* nodes (tagged pre-auth key or admin-console tag), so
///    the untagged bucket is an explicit choice: while a tag filter is
///    active, `includeUntagged` decides whether tagless peers still show.
///    With no tags selected the tag axis is off and `includeUntagged` is
///    irrelevant — everything passes it.
///
/// This is a cosmetic, client-side filter. The authoritative version of
/// "only these people reach these screens" is Tailscale ACLs on port 7447 —
/// but since discovery is netmap-based (not probe-based), ACL-blocked peers
/// still appear in the raw list, and a tag filter is how a user hides them.
public struct PeerListFilter: Codable, Sendable, Equatable {
    public var hideOffline: Bool
    public var selectedTags: Set<String>
    public var includeUntagged: Bool

    public static let `default` = PeerListFilter(
        hideOffline: false, selectedTags: [], includeUntagged: true)

    public init(hideOffline: Bool, selectedTags: Set<String>, includeUntagged: Bool) {
        self.hideOffline = hideOffline
        self.selectedTags = selectedTags
        self.includeUntagged = includeUntagged
    }

    /// True when the filter can hide anything — drives the "filter is on"
    /// icon state and the Clear Filters affordance.
    public var isActive: Bool {
        hideOffline || !selectedTags.isEmpty
    }

    /// Pure decision: does a peer with this online state and tag set pass?
    public func matches(isOnline: Bool, tags: [String]) -> Bool {
        if hideOffline && !isOnline { return false }
        guard !selectedTags.isEmpty else { return true }
        if tags.isEmpty { return includeUntagged }
        return tags.contains(where: selectedTags.contains)
    }

    /// Menu label for an ACL tag: the conventional `tag:` prefix is pure
    /// noise in a list that contains nothing but tags, so strip it — unless
    /// stripping would leave nothing to click on (a bare `"tag:"`, which a
    /// control plane shouldn't emit but a label must survive).
    public static func displayName(forTag tag: String) -> String {
        let stripped = tag.hasPrefix("tag:") ? String(tag.dropFirst(4)) : tag
        return stripped.isEmpty ? tag : stripped
    }
}

/// Persisted peer-list filter. Mirrors `QualitySettingsStore` — plain
/// `UserDefaults` so `AppState.init`'s stored-property initialiser can read
/// the saved value without `@AppStorage`. The `defaults` parameter exists
/// for tests, which use a scratch suite instead of `.standard`.
public enum PeerListFilterStore {
    public static let key = "peerListFilter"

    public static func load(from defaults: UserDefaults = .standard) -> PeerListFilter {
        guard let data = defaults.data(forKey: key) else { return .default }
        guard let decoded = try? JSONDecoder().decode(PeerListFilter.self, from: data) else {
            return .default
        }
        return decoded
    }

    public static func save(_ filter: PeerListFilter, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        defaults.set(data, forKey: key)
    }
}
