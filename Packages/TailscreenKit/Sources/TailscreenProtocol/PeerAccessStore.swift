import Foundation

/// Remembered allow/deny decisions, persisted as one JSON file — the store the
/// **Linux and Windows apps share**.
///
/// The decisions themselves were already portable and tested
/// (`ViewerAccessPolicy.admissionDecision` and friends); only *persistence* was
/// mac-bound, which is why those two hosts can admit a viewer and then have no
/// way to change their mind. Remembered allow, "Deny & Block", and the settings
/// list that shows what you have remembered all need somewhere to write.
///
/// Deliberately **not** the existing `ViewerAccessPolicyStore`, which stays
/// macOS's. Two reasons, and both are structural rather than stylistic:
///
///   * It is an `ObservableObject`. On Linux that name resolves to this
///     module's own stand-in (see `PortabilityShims`), which is a *different
///     protocol* from the identically-named one swift-cross-ui hosts observe —
///     so a store conforming to one could not be observed by the other. Each
///     host owns its reactive wrapper instead, which is exactly why the
///     mutators here return whether they changed anything.
///   * It persists to `UserDefaults`. That is right on macOS and wrong for a
///     GTK or WinUI app, where the natural home is a file beside the account
///     registry.
///
/// Same reasoning, same shape, and the same precedent as `AccountProfileStore`.
/// The *entry* types (`PeerAccessEntry`, `PeerPolicy`) are shared unchanged, so
/// the two stores cannot disagree about what a remembered decision is.
///
/// Not `Sendable`: it owns an unlocked JSON file, so it belongs to exactly one
/// isolation domain. Both hosts keep it inside a `@MainActor` model, and
/// Swift 6's strict checking is what enforces that — a stronger guarantee than
/// annotating it here, which would only force every caller and test to hop.
public final class PeerAccessStore {
    /// All remembered peers, oldest first, so a settings list has a stable
    /// order that does not reshuffle when a display name is refreshed.
    public private(set) var entries: [PeerAccessEntry]

    private let fileURL: URL

    /// `directory` is the host's config root — the same one
    /// `AccountProfileLayout` resolves for `profiles.json`, so remembered
    /// viewers live beside the accounts they were remembered under.
    ///
    /// One file per install rather than per profile, matching macOS. A
    /// StableNodeID is issued by a control plane, so two accounts on different
    /// tailnets have disjoint ID spaces and cannot collide; splitting the file
    /// per profile would buy nothing and lose a decision when someone switches
    /// accounts mid-session.
    public init(directory: String, fileName: String = "viewer-access.json") {
        let root = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(fileName)
        entries = Self.load(from: fileURL)
    }

    /// Remember (or update) a decision. An existing entry keeps its `addedAt`
    /// — that is when you first decided about this peer, and a later rename or
    /// policy flip does not change that — but takes the new policy and name.
    ///
    /// Returns whether anything changed, so a host's reactive wrapper can
    /// re-publish only on a real change.
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

    /// Refresh the cosmetic display name without touching the policy, so a
    /// renamed machine stays readable in settings. No-op for unknown peers or
    /// an unchanged name — a sighting of every peer on every netmap tick must
    /// not rewrite the file.
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
    ///
    /// Reuses the macOS store's projection rather than reimplementing it: the
    /// server's admission gate must read the same map whichever host built it.
    public var policiesByStableID: [String: PeerPolicy] {
        ViewerAccessPolicyStore.policiesByStableID(entries)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// A missing or corrupt file degrades to "nothing remembered" rather than
    /// throwing. That is the safe direction: forgetting a remembered *allow*
    /// costs one approval prompt, and forgetting a remembered *deny* is caught
    /// by the gate, which defaults to asking. Refusing to start because a JSON
    /// file is malformed would be worse than either.
    private static func load(from url: URL) -> [PeerAccessEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PeerAccessEntry].self, from: data)) ?? []
    }
}
