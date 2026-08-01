import Foundation

/// One signed-in account — a distinct Tailscale identity, backed by its own
/// tsnet **state directory** (machine key + config). Switching accounts brings
/// the current node down and up again under a different state dir, so several
/// tailnets/logins can coexist on one machine without clobbering each other's
/// keys. A profile *is* a state directory; everything else here is labelling.
///
/// `statePath` is stored absolute rather than relative to the registry root
/// because the two hosts seed it differently: a fresh profile gets a directory
/// the registry invents, while the FIRST profile on an upgrading install
/// adopts a pre-existing directory that lives outside the `profiles/` subtree
/// (see `AccountProfileLayout.seedStatePath`). One absolute string expresses
/// both; a relative one would need a discriminator.
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
/// from whatever was there before it.
///
/// The platform-specific part of multi-account support is *only* this: Linux
/// wants `$XDG_CONFIG_HOME`, Windows wants `%LOCALAPPDATA%`, and each has its
/// own thing to migrate. Injecting it (rather than branching inside the store)
/// is what lets Linux CI test the Windows layout — including its migration,
/// which is the one part nobody can afford to get wrong, because getting it
/// wrong signs every existing user out.
public struct AccountProfileLayout: Sendable {
    /// Directory holding `profiles.json` and the per-profile `profiles/<uuid>`
    /// state dirs.
    public var root: String

    /// A previous name for `root`, renamed onto it once. Set by the GTK app,
    /// whose config dir was `tailscreen-viewer-gtk` before the executable was
    /// renamed. Nil disables the rename.
    ///
    /// Applied only when `root` does not exist yet, so it can never clobber a
    /// live registry.
    public var legacyRoot: String?

    /// The state directory the FIRST (seeded) profile adopts, instead of a
    /// freshly invented `profiles/<uuid>`.
    ///
    /// This is the upgrade path for a host that shipped single-account: the
    /// old build's one fixed state dir becomes account #1, so introducing the
    /// registry logs nobody out. It is applied unconditionally when set — not
    /// only when the directory already exists — so a first run and a second
    /// run land on the same directory whether or not a login happened in
    /// between, and so a corrupt registry re-seeds onto the login that is
    /// still on disk rather than orphaning it.
    public var seedStatePath: String?

    /// Base word for auto-generated profile names ("Account 1", "Account 2").
    public var namePrefix: String

    public init(
        root: String,
        legacyRoot: String? = nil,
        seedStatePath: String? = nil,
        namePrefix: String = "Account"
    ) {
        self.root = root
        self.legacyRoot = legacyRoot
        self.seedStatePath = seedStatePath
        self.namePrefix = namePrefix
    }

    /// `$XDG_CONFIG_HOME/tailscreen` (or `~/.config/tailscreen`, or
    /// `fallbackDirectory` as a last resort) — the standard Linux per-user
    /// config location, with the pre-rename `tailscreen-viewer-gtk` directory
    /// adopted once.
    ///
    /// No `seedStatePath`: this host has always kept its node state inside the
    /// registry root, so there is no outside directory to adopt.
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
        return AccountProfileLayout(
            root: base + "/tailscreen",
            legacyRoot: base + "/tailscreen-viewer-gtk")
    }

    /// `%LOCALAPPDATA%\Tailscreen` — per-machine, per-user data that must not
    /// roam, because the machine key inside it identifies *this* device to the
    /// tailnet.
    ///
    /// `seedStatePath` is `<root>\tailscale`, which is byte-for-byte the single
    /// fixed directory the pre-registry Windows build used, so upgrading is
    /// invisible: account #1 is the login that is already there.
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
/// Deliberately **not** an `ObservableObject`: on Linux this module supplies
/// its own `ObservableObject`/`Published` stand-ins (see `PortabilityShims`),
/// which are a different protocol from the identically-named ones every
/// swift-cross-ui host observes. A store that conformed to one could not be
/// observed by the other, so the reactive wrapper belongs in each host, over
/// this. The mutating methods return whether they changed anything precisely
/// so such a wrapper can re-publish only on a real change.
///
/// Deliberately **not** `Sendable` either: it owns a JSON file with no lock,
/// so it belongs to exactly one isolation domain. Both hosts keep it inside a
/// `@MainActor` model, and Swift 6's strict checking is what enforces that —
/// a stronger guarantee than a `@MainActor` annotation here, which would only
/// force every caller (and every test) to hop.
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
        // Adopt the pre-rename config directory BEFORE anything creates the
        // new one — once `root` exists the rename is (correctly) skipped, so
        // creating it first would strand the old registry forever.
        if let legacy = layout.legacyRoot,
            !FileManager.default.fileExists(atPath: layout.root),
            FileManager.default.fileExists(atPath: legacy)
        {
            try? FileManager.default.moveItem(atPath: legacy, toPath: layout.root)
        }
        root = layout.root
        namePrefix = layout.namePrefix
        try? FileManager.default.createDirectory(
            atPath: layout.root, withIntermediateDirectories: true)

        let url = URL(fileURLWithPath: layout.root).appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode(Saved.self, from: data),
            !saved.profiles.isEmpty
        {
            profiles = saved.profiles
            // A stored selection naming a profile that is gone falls back to
            // the first rather than leaving `active` pointing at nothing.
            activeID =
                saved.profiles.contains { $0.id == saved.activeID }
                ? saved.activeID : saved.profiles[0].id
        } else {
            // First launch, or a corrupt/unreadable blob: seed one profile
            // rather than resetting anything on disk. With a `seedStatePath`
            // that profile adopts the pre-registry state dir, so the degraded
            // path keeps the existing login too.
            let id = UUID().uuidString
            let seed = AccountProfile(
                id: id, name: "\(layout.namePrefix) 1",
                statePath: layout.seedStatePath ?? Self.freshStatePath(root: layout.root, id: id))
            profiles = [seed]
            activeID = seed.id
        }
        save()
    }

    /// Switch the active profile. Returns false (and changes nothing) when the
    /// id is already active or unknown — an unknown id must never be able to
    /// point the store at a directory that does not exist.
    @discardableResult
    public func setActive(_ id: String) -> Bool {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return false }
        activeID = id
        save()
        return true
    }

    /// Create a profile with a fresh, empty state dir — which is what makes
    /// the next node bring-up prompt for an interactive login — and make it
    /// active, since adding an account is a request to use it.
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

    /// Relabel a profile (e.g. onto the resolved login once the node is up).
    /// Returns false for an unknown id, an empty name, or an unchanged name,
    /// so callers can invoke it after every bring-up without churning.
    @discardableResult
    public func rename(_ id: String, to name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
            profiles[index].name != name, !name.isEmpty
        else { return false }
        profiles[index].name = name
        save()
        return true
    }

    /// Remove a profile from the registry, returning it so the caller can
    /// delete its on-disk state. Refuses the active profile and the last
    /// remaining one (the invariants above); the store never deletes files.
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
