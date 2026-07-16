import Foundation

/// Remembered admission decision for one peer. `allow` skips the approval
/// prompt on every future HELLO; `deny` silently rejects them.
public enum PeerPolicy: String, Codable, Sendable {
    case allow
    case deny
}

/// One remembered peer. Keyed by the Tailscale **StableNodeID**
/// (LocalAPI `PeerStatus.ID`, the "nXXXX…" string) — the only peer
/// identifier that survives IP reassignment, MagicDNS renames, and node-key
/// rotation (see `TailscalePeerDiscovery.mergeKey` for the ID-space
/// pitfalls). `displayName` is cosmetic and refreshed on each sighting so
/// renamed machines stay readable in Settings.
public struct PeerAccessEntry: Codable, Sendable, Identifiable, Equatable {
    public let stableID: String
    public var displayName: String
    public var policy: PeerPolicy
    public let addedAt: Date

    public var id: String { stableID }
}

/// Persistent per-peer allow/deny store backing the "Always Allow" /
/// "Deny & Block" actions and the Settings "Remembered viewers" list.
///
/// `@MainActor` because it's UI-owned state (AppState holds it, SwiftUI
/// renders it). The screen-share server never touches this store — it's
/// handed a value snapshot via `TailscaleScreenShareServer.setAccessPolicies`
/// whenever the entries change, so the `@unchecked Sendable` server never
/// reaches into `UserDefaults` or main-actor state.
///
/// Persistence is a single JSON blob under one `UserDefaults` key. The
/// defaults instance is injectable so tests can use a scratch suite.
@MainActor
public final class ViewerAccessPolicyStore: ObservableObject {
    public static let defaultsKey = "viewerAccessPolicies"

    /// All remembered peers, oldest first (stable Settings ordering).
    @Published private(set) public var entries: [PeerAccessEntry] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
    }

    /// Remember (or update) a decision for `stableID`. An existing entry
    /// keeps its `addedAt` but takes the new policy and display name.
    public func upsert(stableID: String, displayName: String, policy: PeerPolicy) {
        if let idx = entries.firstIndex(where: { $0.stableID == stableID }) {
            entries[idx].displayName = displayName
            entries[idx].policy = policy
        } else {
            entries.append(
                PeerAccessEntry(
                    stableID: stableID, displayName: displayName, policy: policy, addedAt: Date()))
        }
        persist()
    }

    /// Forget a peer — the next HELLO from it goes through the normal
    /// approval flow again.
    public func remove(stableID: String) {
        entries.removeAll { $0.stableID == stableID }
        persist()
    }

    /// Refresh the cosmetic display name without touching the policy.
    /// No-op for unknown peers.
    public func refreshDisplayName(stableID: String, displayName: String) {
        guard let idx = entries.firstIndex(where: { $0.stableID == stableID }) else { return }
        guard entries[idx].displayName != displayName else { return }
        entries[idx].displayName = displayName
        persist()
    }

    public func policy(for stableID: String) -> PeerPolicy? {
        entries.first(where: { $0.stableID == stableID })?.policy
    }

    /// Value snapshot for `TailscaleScreenShareServer.setAccessPolicies`.
    public var policiesByStableID: [String: PeerPolicy] {
        Self.policiesByStableID(entries)
    }

    /// Pure projection shared by the instance property and AppState's
    /// `$entries` subscription (which receives the new array before the
    /// property is written).
    public nonisolated static func policiesByStableID(_ entries: [PeerAccessEntry]) -> [String: PeerPolicy] {
        Dictionary(entries.map { ($0.stableID, $0.policy) }, uniquingKeysWith: { _, last in last })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [PeerAccessEntry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([PeerAccessEntry].self, from: data) else {
            return []
        }
        return decoded
    }
}
