import Foundation

/// The "Require approval for new viewers" preference, as a portable decision
/// plus the storage the swift-cross-ui apps read it from.
///
/// The gate itself lives in `TailscaleScreenShareServer.setRequireApproval`,
/// which defaults **off** — a server started and never told otherwise admits
/// whoever reaches port 7447. That default is right for the server (a headless
/// automation sharer wants open door) and wrong for every app with a person
/// in front of it, so each host has to assert the safe value. This is the
/// shared answer to "which value", so the GTK and Windows apps cannot drift
/// from the macOS posture or from each other.
///
/// Three rules, mirroring the macOS app's `ViewerApprovalDefaults`:
///
///   * **Default on.** A desktop app that silently admits anyone who can dial
///     the port is a worse default than one extra click.
///   * **Tri-state migration.** `nil` (never touched) is distinguishable from
///     a stored `false` (an explicit opt-out), so the on-by-default rule does
///     not quietly re-enable the gate for someone who turned it off. A plain
///     `bool(forKey:)` cannot express this — it reports `false` for both.
///   * **`TAILSCREEN_OPEN_DOOR=1` forces it off**, for the scripted harnesses
///     whose automated viewers would otherwise park on a prompt with nobody
///     around to answer it. Never set in production.
///
/// `resolve` is separated from `load` so the rules above are testable without
/// a `UserDefaults` suite — the storage half is two lines and the decision
/// half is the part that can be wrong.
public enum ViewerApprovalPreference {
    /// Same key the macOS app persists under. Deliberately identical: it is
    /// the same preference under the same name, and nothing is gained by
    /// giving each platform its own spelling of it.
    public static let defaultsKey = "requireViewerApproval"
    public static let openDoorEnvKey = "TAILSCREEN_OPEN_DOOR"

    /// The gate's value given what was stored and whether open-door mode is
    /// forced. `stored` is `nil` on a never-touched install.
    public static func resolve(stored: Bool?, openDoor: Bool) -> Bool {
        if openDoor { return false }
        return stored ?? true
    }

    /// Whether `environment` asks for open-door mode.
    public static func openDoorForced(_ environment: [String: String]) -> Bool {
        environment[openDoorEnvKey] == "1"
    }

    public static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolve(
            stored: defaults.object(forKey: defaultsKey) as? Bool,
            openDoor: openDoorForced(environment))
    }

    /// Persist an explicit choice.
    ///
    /// Saving under open-door mode still records the user's choice: the env
    /// var overrides this run, it is not a preference change, and writing
    /// `false` through it would let a harness run leak into the next real one.
    public static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }
}
