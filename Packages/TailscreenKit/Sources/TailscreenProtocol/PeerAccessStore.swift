import Foundation

/// Remembered allow/deny decisions, persisted as one JSON file — the store
/// **Linux and Windows apps share**.
///
/// Deliberately not the existing `ViewerAccessPolicyStore`, which stays
/// macOS's: that one is an `ObservableObject` (a different protocol under
/// Linux's stand-in, see `PortabilityShims`) and persists to `UserDefaults`,
/// wrong for a GTK/WinUI app. Same precedent as `AccountProfileStore`. The
/// entry types (`PeerAccessEntry`, `PeerPolicy`) are shared unchanged.
///
/// Not `Sendable`: owns an unlocked JSON file, belongs to one isolation
/// domain. Both hosts keep it inside a `@MainActor` model.
public final class PeerAccessStore {
    /// All remembered peers, oldest first, so a settings list has a stable
    /// order that does not reshuffle when a display name is refreshed.
    public private(set) var entries: [PeerAccessEntry]

    private let fileURL: URL

    /// `directory` is the host's config root — same one `AccountProfileLayout`
    /// resolves for `profiles.json`. One file per install, matching macOS: a
    /// StableNodeID is per-tailnet-unique, so per-profile splitting would only
    /// lose a decision on account switch.
    public init(directory: String, fileName: String = "viewer-access.json") {
        let root = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(fileName)
        entries = Self.load(from: fileURL)
    }

    /// Remember (or update) a decision. An existing entry keeps its
    /// `addedAt` but takes the new policy and name. Returns whether anything
    /// changed, so a host's reactive wrapper re-publishes only on real change.
    @discardableResult
    public func upsert(stableID: String, displayName: String, policy: PeerPolicy) -> Bool {
        if let index = entries.firstIndex(where: { $0.stableID == stableID }) {
            guard entries[index].displayName != displayName || entries[index].policy != policy
            else { return false }
            entries[index].displayName = displayName
            entries[index].policy = policy
        } else {
            entries.append(
                PeerAccessEntry(
                    stableID: stableID, displayName: displayName, policy: policy, addedAt: Date()))
        }
        persist()
        return true
    }

    /// Forget a peer, so its next HELLO goes through the normal approval flow
    /// again. Returns false for an unknown id.
    @discardableResult
    public func remove(stableID: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.stableID == stableID }
        guard entries.count != before else { return false }
        persist()
        return true
    }

    /// Refresh the cosmetic display name without touching the policy. No-op
    /// for unknown peers or an unchanged name, so a netmap tick sighting
    /// every peer doesn't rewrite the file.
    @discardableResult
    public func refreshDisplayName(stableID: String, displayName: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.stableID == stableID }),
            entries[index].displayName != displayName
        else { return false }
        entries[index].displayName = displayName
        persist()
        return true
    }

    public func policy(for stableID: String) -> PeerPolicy? {
        entries.first(where: { $0.stableID == stableID })?.policy
    }

    /// Value snapshot for `TailscaleScreenShareServer.setAccessPolicies`.
    /// Reuses the macOS store's projection so the admission gate reads the
    /// same map regardless of which host built it.
    public var policiesByStableID: [String: PeerPolicy] {
        ViewerAccessPolicyStore.policiesByStableID(entries)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// A missing or corrupt file degrades to "nothing remembered" rather than
    /// throwing — safer than refusing to start, since the gate defaults to
    /// asking either way.
    private static func load(from url: URL) -> [PeerAccessEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PeerAccessEntry].self, from: data)) ?? []
    }
}
