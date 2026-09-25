import Foundation

/// One signed-in account — a distinct Tailscale identity, backed by its own
/// tsnet state directory. Switching accounts brings the node down and up
/// under a different state dir. A profile *is* a state directory; everything
/// else here is labelling.
///
/// `statePath` is absolute, not relative to the registry root, because a
/// fresh profile gets an invented directory while the first profile on an
/// upgrading install adopts a pre-existing one outside `profiles/` (see
/// `AccountProfileLayout.seedStatePath`).
public struct AccountProfile: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    /// Display label for the account menu. Starts as "Account N" and is
    /// replaced by the resolved login once the node reports one.
    public var name: String
    public let statePath: String

    public init(id: String, name: String, statePath: String) {
        self.id = id
        self.name = name
        self.statePath = statePath
    }
}

/// Where an `AccountProfileStore` keeps its registry, and what it must adopt
/// from whatever was there before it. Injected rather than branched inside
/// the store, so Linux CI can test the Windows layout's migration too.
public struct AccountProfileLayout: Sendable {
    /// Directory holding `profiles.json` and the per-profile `profiles/<uuid>`
    /// state dirs.
    public var root: String

    /// The state directory the first (seeded) profile adopts, instead of a
    /// freshly invented `profiles/<uuid>` — the upgrade path for a host that
    /// shipped single-account, so introducing the registry logs nobody out.
    /// Applied unconditionally when set, so a corrupt registry re-seeds onto
    /// the login still on disk rather than orphaning it.
    public var seedStatePath: String?

    /// Base word for auto-generated profile names ("Account 1", "Account 2").
    public var namePrefix: String

    public init(
        root: String,
        seedStatePath: String? = nil,
        namePrefix: String = "Account"
    ) {
        self.root = root
        self.seedStatePath = seedStatePath
        self.namePrefix = namePrefix
    }

    /// `$XDG_CONFIG_HOME/tailscreen` (or `~/.config/tailscreen`, or
    /// `fallbackDirectory`) — the standard Linux per-user config location. No
    /// `seedStatePath`: this host's node state has always lived in the registry root.
    public static func xdg(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectory: String = FileManager.default.currentDirectoryPath
    ) -> AccountProfileLayout {
        let base: String
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else if let home = environment["HOME"], !home.isEmpty {
            base = home + "/.config"
        } else {
            base = fallbackDirectory
        }
        return AccountProfileLayout(root: base + "/tailscreen")
    }

    /// `%LOCALAPPDATA%\Tailscreen` — must not roam, since the machine key
    /// inside identifies this device. `seedStatePath` is `<root>\tailscale`,
    /// the pre-registry Windows build's fixed directory, so upgrading is invisible.
    public static func windowsLocalAppData(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectory: String = NSHomeDirectory()
    ) -> AccountProfileLayout {
        let base = environment["LOCALAPPDATA"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackDirectory
        let root = URL(fileURLWithPath: base).appendingPathComponent("Tailscreen").path
        return AccountProfileLayout(
            root: root,
            seedStatePath: URL(fileURLWithPath: root).appendingPathComponent("tailscale").path)
    }
}

/// Persisted list of account profiles plus the active selection, stored as
/// `profiles.json` under the layout's root.
///
/// Deliberately not an `ObservableObject` — Linux's `PortabilityShims` stand-in
/// is a different protocol from swift-cross-ui's, so the reactive wrapper
/// belongs in each host. Mutating methods return whether they changed
/// anything, so a wrapper can re-publish only on a real change.
///
/// Deliberately not `Sendable` either: it owns a JSON file with no lock, so
/// it belongs to exactly one isolation domain (each host's `@MainActor` model).
///
/// Invariants: at least one profile always exists, `activeID` always names an
/// existing profile, and neither the active nor the last remaining profile can
/// be removed.
public final class AccountProfileStore {
    public private(set) var profiles: [AccountProfile]
    public private(set) var activeID: String

    private let root: String
    private let namePrefix: String
    private var storeURL: URL {
        URL(fileURLWithPath: root).appendingPathComponent("profiles.json")
    }

    /// The active profile. `profiles` is never empty, so the fallback is a
    /// formality that also makes the property non-optional at every call site.
    public var active: AccountProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    public init(layout: AccountProfileLayout) {
        let fm = FileManager.default

        root = layout.root
        namePrefix = layout.namePrefix
        try? fm.createDirectory(atPath: layout.root, withIntermediateDirectories: true)

        let url = URL(fileURLWithPath: layout.root).appendingPathComponent("profiles.json")
        let saved = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved, !saved.profiles.isEmpty {
            profiles = saved.profiles
            // A stored selection naming a gone profile falls back to the first.
            activeID =
                saved.profiles.contains { $0.id == saved.activeID }
                ? saved.activeID : saved.profiles[0].id
        } else {
            // First launch, or corrupt/unreadable: seed one profile, adopting
            // `seedStatePath` if set so a degraded path keeps the existing login.
            let id = UUID().uuidString
            let seed = AccountProfile(
                id: id, name: "\(layout.namePrefix) 1",
                statePath: layout.seedStatePath ?? Self.freshStatePath(root: layout.root, id: id))
            profiles = [seed]
            activeID = seed.id
        }
        save()
    }

    /// Switch the active profile. Returns false when the id is already
    /// active or unknown.
    @discardableResult
    public func setActive(_ id: String) -> Bool {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return false }
        activeID = id
        save()
        return true
    }

    /// Create a profile with a fresh, empty state dir (prompting the next
    /// node bring-up for interactive login) and make it active.
    @discardableResult
    public func addProfile() -> AccountProfile {
        let id = UUID().uuidString
        let profile = AccountProfile(
            id: id, name: "\(namePrefix) \(profiles.count + 1)",
            statePath: Self.freshStatePath(root: root, id: id))
        profiles.append(profile)
        activeID = profile.id
        save()
        return profile
    }

    /// Relabel a profile. Returns false for an unknown id, empty name, or
    /// unchanged name, so callers can invoke it after every bring-up without
    /// churning.
    @discardableResult
    public func rename(_ id: String, to name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
            profiles[index].name != name, !name.isEmpty
        else { return false }
        profiles[index].name = name
        save()
        return true
    }

    /// Remove a profile, returning it so the caller can delete its on-disk
    /// state. Refuses the active profile and the last remaining one; the
    /// store never deletes files.
    @discardableResult
    public func remove(_ id: String) -> AccountProfile? {
        guard id != activeID, profiles.count > 1,
            let index = profiles.firstIndex(where: { $0.id == id })
        else { return nil }
        let removed = profiles.remove(at: index)
        save()
        return removed
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var profiles: [AccountProfile]
        var activeID: String
    }

    private func save() {
        let saved = Saved(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func freshStatePath(root: String, id: String) -> String {
        URL(fileURLWithPath: root)
            .appendingPathComponent("profiles")
            .appendingPathComponent(id)
            .path
    }
}
