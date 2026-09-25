import Foundation

/// The "Require approval for new viewers" preference, as a portable decision
/// plus the storage all three apps read it from.
///
/// The gate itself (`TailscaleScreenShareServer.setRequireApproval`) defaults
/// **off** — right for a headless automation sharer, wrong for any app with
/// a person in front of it — so each host asserts the safe value from this
/// one shared type instead of drifting apart.
///
/// Three rules:
///
///   * **Default on.** Silently admitting anyone who can dial the port is
///     worse than one extra click.
///   * **Tri-state migration.** `nil` (never touched) is distinguishable
///     from a stored `false` (explicit opt-out), so on-by-default doesn't
///     quietly re-enable the gate for someone who turned it off. Plain
///     `bool(forKey:)` can't express this.
///   * **`TAILSCREEN_OPEN_DOOR=1` forces it off**, for scripted harnesses
///     whose automated viewers would otherwise park on an unanswerable
///     prompt. Never set in production.
///
/// `resolve` is separated from `load` so the rules are testable without a
/// `UserDefaults` suite.
public enum ViewerApprovalPreference {
    /// Same key the macOS app has always persisted under, so existing
    /// installs keep their stored choice.
    public static let defaultsKey = "requireViewerApproval"
    public static let openDoorEnvKey = "TAILSCREEN_OPEN_DOOR"

    /// What storage holds for the gate. An enum rather than `Bool?` (like
    /// `PeerSharingState`): the third state is real, not a missing answer,
    /// and naming it stops `unset` from being read as "off".
    public enum Stored: Equatable, Sendable {
        /// Never touched — the on-by-default rule applies.
        case unset
        /// An explicit choice the user made, which must survive.
        case chosen(Bool)
    }

    /// The gate's value given what was stored and whether open-door mode is
    /// forced.
    public static func resolve(stored: Stored, openDoor: Bool) -> Bool {
        if openDoor { return false }
        switch stored {
        case .unset: return true
        case .chosen(let value): return value
        }
    }

    /// Whether `environment` asks for open-door mode.
    public static func openDoorForced(_ environment: [String: String]) -> Bool {
        environment[openDoorEnvKey] == "1"
    }

    public static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // `object(forKey:)`, not `bool(forKey:)`: the latter reports false for
        // both "absent" and "stored false", which is precisely the distinction
        // the tri-state exists to keep.
        let stored: Stored =
            (defaults.object(forKey: defaultsKey) as? Bool).map(Stored.chosen) ?? .unset
        return resolve(stored: stored, openDoor: openDoorForced(environment))
    }

    /// Persist an explicit choice. Saving under open-door mode still
    /// records the user's choice — the env var overrides this run only,
    /// it's not a preference change.
    public static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }
}
