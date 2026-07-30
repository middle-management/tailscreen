import Foundation
import SwiftCrossUI

/// One viewer account — a distinct Tailscale identity, backed by its own tsnet
/// state directory (node key + config). Switching profiles brings the current
/// node down and up under a different state dir, so several tailnets/logins can
/// coexist without clobbering each other's keys (the mac app's multi-account
/// model from #141, pared to what a viewer needs).
struct ViewerProfile: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    let statePath: String
}

/// Persisted list of viewer profiles + the active selection. Stored as JSON
/// under the XDG config dir. `@MainActor` because the account menu (main thread)
/// mutates it; `ObservableObject` so the header re-renders on switch/add/rename.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ViewerProfile]
    @Published private(set) var activeID: String

    /// Directory holding `profiles.json` and the per-profile state dirs.
    private let root: String
    private var storeURL: URL { URL(fileURLWithPath: root).appendingPathComponent("profiles.json") }

    /// The active profile (falls back to the first — `profiles` is never empty).
    var active: ViewerProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    init() {
        root = Self.configRoot()
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)

        // Load the persisted store, or seed a single default profile.
        let url = URL(fileURLWithPath: root).appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode(Saved.self, from: data),
            !saved.profiles.isEmpty {
            profiles = saved.profiles
            activeID = saved.profiles.contains { $0.id == saved.activeID }
                ? saved.activeID : saved.profiles[0].id
        } else {
            let seed = Self.makeProfile(name: "Account 1", root: root)
            profiles = [seed]
            activeID = seed.id
        }
        save()
    }

    /// Switch the active profile. No-op if already active or unknown.
    func setActive(_ id: String) {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    /// Create a new profile (fresh state dir → interactive login on bring-up),
    /// make it active, and return it.
    @discardableResult
    func addProfile() -> ViewerProfile {
        let profile = Self.makeProfile(name: "Account \(profiles.count + 1)", root: root)
        profiles.append(profile)
        activeID = profile.id
        save()
        return profile
    }

    /// Update a profile's display name (e.g. to the resolved tailnet/login once
    /// the node is up). Persists only on a real change.
    func rename(_ id: String, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
            profiles[index].name != name, !name.isEmpty
        else { return }
        profiles[index].name = name
        save()
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var profiles: [ViewerProfile]
        var activeID: String
    }

    private func save() {
        let saved = Saved(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func makeProfile(name: String, root: String) -> ViewerProfile {
        let id = UUID().uuidString
        let statePath = URL(fileURLWithPath: root)
            .appendingPathComponent("profiles")
            .appendingPathComponent(id)
            .path
        return ViewerProfile(id: id, name: name, statePath: statePath)
    }

    /// `$XDG_CONFIG_HOME/tailscreen` (or `~/.config/…`, or the CWD as a last
    /// resort) — the standard Linux per-user config location. The directory was
    /// `tailscreen-viewer-gtk` before the executable rename; an existing old
    /// directory is moved into place once so profiles and node state survive.
    private static func configRoot() -> String {
        let env = ProcessInfo.processInfo.environment
        let base: String
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else if let home = env["HOME"], !home.isEmpty {
            base = home + "/.config"
        } else {
            base = FileManager.default.currentDirectoryPath
        }
        let root = base + "/tailscreen"
        let legacy = base + "/tailscreen-viewer-gtk"
        if !FileManager.default.fileExists(atPath: root),
            FileManager.default.fileExists(atPath: legacy) {
            try? FileManager.default.moveItem(atPath: legacy, toPath: root)
        }
        return root
    }
}
