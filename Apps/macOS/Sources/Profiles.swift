import Combine
import Foundation

/// One saved Tailscale login ("profile", Tailscale-app style). A profile
/// is fundamentally a tsnet **state directory** — the on-disk node state
/// carries the machine key and session, so keeping one directory per
/// profile lets several accounts stay logged in with exactly one active
/// node at a time.
struct TailscreenProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Copied from `TailscaleUserProfile` after first login, so the account
    /// menu can label the profile while inactive. Empty until then.
    var displayName: String
    var loginName: String
    /// Empty when unknown; the UI falls back to a monogram.
    var profilePicURL: String
    /// Disambiguates a login name shared across tailnets (e.g. one GitHub
    /// identity, several orgs). Empty until known.
    var tailnetName: String
    /// Relative to the Tailscreen app-support directory, WITHOUT the
    /// `TAILSCREEN_INSTANCE` suffix. Migrated default profile owns the
    /// pre-profiles `"tailscale"` root; new profiles get
    /// `"profiles/<uuid>/tailscale"`.
    let stateDirectory: String

    var hasSignedIn: Bool { !loginName.isEmpty }

    /// Menu row title: tailnet-qualified once known, since the login name
    /// alone can collide across profiles.
    var menuTitle: String {
        guard hasSignedIn else { return "" }
        return tailnetName.isEmpty ? loginName : "\(loginName) — \(tailnetName)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, loginName, profilePicURL, tailnetName, stateDirectory
    }

    init(
        id: UUID, displayName: String, loginName: String, tailnetName: String = "",
        profilePicURL: String = "", stateDirectory: String
    ) {
        self.id = id
        self.displayName = displayName
        self.loginName = loginName
        self.profilePicURL = profilePicURL
        self.tailnetName = tailnetName
        self.stateDirectory = stateDirectory
    }

    /// Custom decode solely so registries persisted before `tailnetName`
    /// existed keep decoding, instead of hitting the store's corrupt-blob
    /// fallback and resetting the profile list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        loginName = try container.decode(String.self, forKey: .loginName)
        tailnetName = try container.decodeIfPresent(String.self, forKey: .tailnetName) ?? ""
        profilePicURL = try container.decodeIfPresent(String.self, forKey: .profilePicURL) ?? ""
        stateDirectory = try container.decode(String.self, forKey: .stateDirectory)
    }

    /// `<appSupport>/Tailscreen/<stateDirectory><instanceSuffix>`. Suffix
    /// appended at resolve time (not stored) so `test-local.sh` instances
    /// keep isolated machine keys per profile.
    func statePath(appSupport: URL, instanceSuffix: String) -> String {
        appSupport
            .appendingPathComponent("Tailscreen/\(stateDirectory)\(instanceSuffix)")
            .path
    }
}

/// Invariants: at least one profile always exists, the active id always
/// refers to an existing profile, and the active (or last remaining) profile
/// can't be removed.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [TailscreenProfile]
    @Published private(set) var activeProfileID: UUID

    private let defaults: UserDefaults
    private static let profilesKey = "tailscreenProfiles"
    private static let activeKey = "tailscreenActiveProfileID"

    /// The first profile is rooted here so existing single-account installs
    /// keep their login without file moves.
    static let legacyStateDirectory = "tailscale"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.profilesKey)
        var loaded =
            data.flatMap { try? JSONDecoder().decode([TailscreenProfile].self, from: $0) } ?? []
        if loaded.isEmpty {
            // First launch or corrupt blob: degrade to a single default profile.
            loaded = [
                TailscreenProfile(
                    id: UUID(), displayName: "", loginName: "",
                    stateDirectory: Self.legacyStateDirectory)
            ]
        }
        self.profiles = loaded
        let storedActive = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        self.activeProfileID = loaded.first { $0.id == storedActive }?.id ?? loaded[0].id
        persist()
    }

    var activeProfile: TailscreenProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    /// Create a fresh, not-yet-signed-in profile with its own state dir.
    @discardableResult
    func addProfile() -> TailscreenProfile {
        let id = UUID()
        let profile = TailscreenProfile(
            id: id, displayName: "", loginName: "",
            stateDirectory: "profiles/\(id.uuidString)/tailscale")
        profiles.append(profile)
        persist()
        return profile
    }

    /// Unknown ids are ignored so a stale menu click can't point at a
    /// nonexistent directory.
    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        persist()
    }

    /// No-op when nothing changed, so callers can invoke it after every
    /// login/restore.
    func updateActiveIdentity(
        displayName: String, loginName: String, tailnetName: String, profilePicURL: String = ""
    ) {
        guard let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        guard
            profiles[idx].displayName != displayName || profiles[idx].loginName != loginName
                || profiles[idx].tailnetName != tailnetName
                || profiles[idx].profilePicURL != profilePicURL
        else { return }
        profiles[idx].displayName = displayName
        profiles[idx].loginName = loginName
        profiles[idx].tailnetName = tailnetName
        profiles[idx].profilePicURL = profilePicURL
        persist()
    }

    /// Refuses the active profile and the last remaining one. Returns the
    /// removed entry so the caller can delete its on-disk state.
    @discardableResult
    func remove(_ id: UUID) -> TailscreenProfile? {
        guard id != activeProfileID, profiles.count > 1,
            let idx = profiles.firstIndex(where: { $0.id == id })
        else { return nil }
        let removed = profiles.remove(at: idx)
        persist()
        return removed
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        defaults.set(activeProfileID.uuidString, forKey: Self.activeKey)
    }
}
