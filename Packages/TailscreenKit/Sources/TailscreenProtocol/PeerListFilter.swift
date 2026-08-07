import Foundation

/// The viewer-side peer-list filter: which discovered Tailscreen peers the
/// menubar's AVAILABLE SCREENS section actually shows. Two axes, both
/// derived from netmap data the discovery layer already carries (no probes,
/// no wire change):
///
///  - **Status** — `hideOffline` drops rows tsnet reports unreachable, and
///    `onlySharing` keeps only peers whose fetched `.metadataResponse` said
///    `isSharing`. Sharing state is a *fetched* fact (a per-peer TCP dial,
///    see `TailscreenMetadataClient`), so it is tri-state at match time
///    (`PeerSharingState`): `.sharing` / `.notSharing` / `.unknown` (no
///    answer yet, peer offline, or a legacy build that doesn't speak
///    `.metadataRequest`). While `onlySharing` is on, `.unknown`
///    deliberately hides — the user asked for screens they can actually
///    watch, and rows appear as answers land.
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
    /// fields) loads with the new axes off instead of resetting the user's
    /// whole filter to `.default` via the store's decode-failure path.
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

/// A peer's sharing state as known to the viewer — the input to the
/// filter's `onlySharing` axis. Deliberately an enum, not `Bool?`: the
/// unknown case is load-bearing (a legacy peer or unanswered dial must
/// never read as "not sharing" in code that displays state, and must hide
/// under `onlySharing` by explicit choice, not optional coincidence).
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
/// Two lines of code, and every host had written them slightly differently.
/// The GTK picker's manual refresh cleared a peer's status on a no-answer while
/// its 10 s quiet refresh kept the previous one, so the same chip meant
/// different things depending on which pass had run last — and a machine that
/// stopped sharing between sweeps kept saying "Sharing" for as long as it also
/// stopped answering. macOS and the Windows hub already clear.
///
/// **A no-answer clears the entry.** `nil` from `TailscreenMetadataClient` is
/// status-UNKNOWN — a timeout, an EOF, a legacy build dropping the unknown byte
/// — and the one thing it is not is evidence about what that machine is doing
/// now. The alternative (keep the last answer) is stale-positive by
/// construction: the chip's failure mode becomes "invites you to connect to a
/// share that ended", which is the failure a person acts on, whereas
/// `.unknown` renders as no chip and hides under the "Only screens being
/// shared" axis — visibly nothing rather than confidently wrong.
///
/// Pure, and in this tier for the same reason `PeerListFilter` is: all three
/// hubs project the same cache through the same tri-state, and a divergence
/// here is invisible until somebody dials a screen that is not there.
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

    /// Drop entries for peers the latest discovery no longer lists.
    ///
    /// Without this a peer that leaves the tailnet keeps its last answer, so
    /// the same id coming back later shows a stale chip until its next probe
    /// lands — and a peer that never comes back keeps its row's worth of the
    /// map for the life of the process.
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
