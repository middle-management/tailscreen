import Foundation

/// The viewer-side peer-list filter: which discovered Tailscreen peers the
/// menubar's AVAILABLE SCREENS section shows. Two axes, both derived from
/// netmap data already on hand (no probes, no wire change):
///
///  - **Status** — `hideOffline` drops unreachable rows; `onlySharing` keeps
///    only peers whose fetched `.metadataResponse` said `isSharing`. Sharing
///    state is tri-state (`PeerSharingState`): `.sharing`/`.notSharing`/
///    `.unknown` (no answer yet, offline, or legacy peer). `onlySharing`
///    deliberately hides `.unknown` — rows appear as answers land.
///  - **Tags** — `selectedTags` keeps peers carrying at least one selected
///    ACL tag. `includeUntagged` decides whether tagless peers still show
///    while a tag filter is active; irrelevant when none is selected.
///
/// Cosmetic, client-side only — the authoritative access control is
/// Tailscale ACLs on port 7447. Since discovery is netmap- not probe-based,
/// ACL-blocked peers still appear in the raw list; the tag filter hides them.
public struct PeerListFilter: Codable, Sendable, Equatable {
    public var hideOffline: Bool
    public var selectedTags: Set<String>
    public var includeUntagged: Bool
    public var onlySharing: Bool

    public static let `default` = PeerListFilter(
        hideOffline: false, selectedTags: [], includeUntagged: true)

    public init(
        hideOffline: Bool, selectedTags: Set<String>, includeUntagged: Bool,
        onlySharing: Bool = false
    ) {
        self.hideOffline = hideOffline
        self.selectedTags = selectedTags
        self.includeUntagged = includeUntagged
        self.onlySharing = onlySharing
    }

    /// Decode-with-fallback so a filter persisted by an older build (fewer
    /// fields) loads with the new axes off instead of resetting to `.default`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hideOffline = try container.decodeIfPresent(Bool.self, forKey: .hideOffline) ?? false
        selectedTags =
            try container.decodeIfPresent(Set<String>.self, forKey: .selectedTags) ?? []
        includeUntagged =
            try container.decodeIfPresent(Bool.self, forKey: .includeUntagged) ?? true
        onlySharing = try container.decodeIfPresent(Bool.self, forKey: .onlySharing) ?? false
    }

    /// True when the filter can hide anything — drives the "filter is on"
    /// icon state and the Clear Filters affordance.
    public var isActive: Bool {
        hideOffline || onlySharing || !selectedTags.isEmpty
    }

    /// Pure decision: does a peer with this online state, tag set, and
    /// fetched sharing state pass?
    public func matches(
        isOnline: Bool, tags: [String], sharing: PeerSharingState = .unknown
    ) -> Bool {
        if hideOffline && !isOnline { return false }
        if onlySharing && sharing != .sharing { return false }
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

/// A peer as the LIST needs to see it: an identity to look the metadata
/// sweep's answer up by, plus the two netmap facts the filter's axes read.
/// Lets one filter serve macOS's `TailscreenPeer` and `DiscoveredSharer` in
/// both swift-cross-ui apps via empty extensions in the tiers that own them.
public protocol PeerListRow {
    /// The key the sweep's `shareInfo` dictionary is populated under.
    var id: String { get }
    var isOnline: Bool { get }
    /// Tailscale ACL tags, empty for an untagged node (a filterable state,
    /// `includeUntagged`, not absence of data).
    var tags: [String] { get }
}

extension PeerListFilter {
    /// The rows this filter admits, in the input's order. `shareInfo` is the
    /// metadata sweep's answers keyed by row id; a missing entry projects to
    /// `.unknown`, never "not sharing" (`shareInfo[id]?.isSharing == true`
    /// would quietly claim a fact the wire never carried).
    public func narrow<Row: PeerListRow>(
        _ rows: [Row], shareInfo: [String: TailscreenMetadata] = [:]
    ) -> [Row] {
        rows.filter {
            matches(
                isOnline: $0.isOnline, tags: $0.tags,
                sharing: PeerSharingState(fetched: shareInfo[$0.id]))
        }
    }

    /// The tags a filter menu should offer: every tag across the RAW list,
    /// plus any tag currently selected (sorted, stable across sweeps).
    /// Including `selectedTags` matters: deriving from present peers alone
    /// would drop a selected tag's row when its last peer goes offline,
    /// stranding the user with no way to switch the filter back off.
    public func knownTags<Row: PeerListRow>(in rows: [Row]) -> [String] {
        var union = selectedTags
        for row in rows { union.formUnion(row.tags) }
        return union.sorted()
    }
}

/// A peer's sharing state as known to the viewer — input to `onlySharing`.
/// Enum, not `Bool?`: the unknown case is load-bearing, so a legacy peer or
/// unanswered dial can never read as "not sharing".
public enum PeerSharingState: Sendable, Equatable {
    case sharing
    case notSharing
    case unknown

    /// Project a fetched `.metadataResponse` (nil = no answer) onto the
    /// tri-state.
    public init(fetched metadata: TailscreenMetadata?) {
        switch metadata {
        case .some(let metadata):
            self = metadata.isSharing ? .sharing : .notSharing
        case .none:
            self = .unknown
        }
    }
}

/// Upkeep of the per-peer sharing-status map every hub keeps behind
/// ``PeerSharingState`` — the cache the metadata sweep fills and the rows'
/// sharing chip reads.
///
/// **A no-answer clears the entry.** `nil` from `TailscreenMetadataClient` is
/// status-UNKNOWN, not evidence the machine stopped sharing; keeping the
/// last answer would be stale-positive by construction (inviting a share
/// that already ended), whereas `.unknown` renders as no chip.
public enum PeerShareStatusMap {
    /// Fold one probe answer in. `fetched == nil` removes the entry.
    public static func recording(
        _ fetched: TailscreenMetadata?, for id: String,
        in statuses: [String: TailscreenMetadata]
    ) -> [String: TailscreenMetadata] {
        var next = statuses
        next[id] = fetched
        return next
    }

    /// Drop entries for peers the latest discovery no longer lists, so a
    /// peer leaving the tailnet doesn't keep a stale chip (or a permanent
    /// map entry) for the life of the process.
    public static func pruned(
        _ statuses: [String: TailscreenMetadata], toPresent ids: Set<String>
    ) -> [String: TailscreenMetadata] {
        statuses.filter { ids.contains($0.key) }
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
