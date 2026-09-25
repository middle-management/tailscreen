import Foundation

/// Whether diagnostics recording is on, as a portable decision plus the
/// storage all three apps read it from. Same shape as
/// ``ViewerApprovalPreference``: a tri-state store, decision split from
/// storage, and an env override for harnesses.
///
/// **A release candidate records by default; a shipped release does not.**
/// Candidate testers agreed to look for problems, and the exercise is
/// pointless if the report is "it didn't work" with nothing attached.
/// Shipped-release recording is opt-in from Settings. An explicit choice
/// outranks the channel default in every direction and survives a channel change.
public enum DiagnosticsPreference {

    /// Storage key. One spelling across all three apps.
    public static let defaultsKey = "recordDiagnostics"

    /// Forces the answer for a whole run, either way:
    /// `TAILSCREEN_DIAGNOSTICS=1` on, `=0` off. For the scripted harnesses and
    /// for reproducing a user's setting without changing theirs.
    public static let envKey = "TAILSCREEN_DIAGNOSTICS"

    /// What storage holds. An enum, not `Bool?` — the third state is real,
    /// and naming it stops `unset` from being read as "off".
    public enum Stored: Equatable, Sendable {
        /// Never touched — the channel default applies.
        case unset
        /// An explicit choice, which must survive a channel change.
        case chosen(Bool)
    }

    /// What the environment says, if anything. An enum, not `Bool?`, for the
    /// same reason ``Stored`` is one.
    public enum Override: Equatable, Sendable {
        /// No `TAILSCREEN_DIAGNOSTICS` in the environment.
        case unset
        /// The variable pinned the answer for this run.
        case forced(Bool)
    }

    /// The decision.
    public static func resolve(
        stored: Stored,
        channel: ReleaseChannel,
        override: Override = .unset
    ) -> Bool {
        // The env override outranks even an explicit choice, so a harness run stays reproducible.
        if case .forced(let value) = override { return value }
        switch stored {
        case .chosen(let value): return value
        case .unset: return channel.recordsDiagnosticsByDefault
        }
    }

    /// What `environment` forces, if anything. Only the exact `"1"` and
    /// `"0"` count — a stray `TAILSCREEN_DIAGNOSTICS=true` means nothing.
    public static func forcedBy(_ environment: [String: String]) -> Override {
        switch environment[envKey] {
        case "1": return .forced(true)
        case "0": return .forced(false)
        default: return .unset
        }
    }

    public static func load(
        defaults: UserDefaults = .standard,
        channel: ReleaseChannel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // `object(forKey:)`, not `bool(forKey:)`, which conflates "absent" and "stored false".
        let stored: Stored =
            (defaults.object(forKey: defaultsKey) as? Bool).map(Stored.chosen) ?? .unset
        return resolve(stored: stored, channel: channel, override: forcedBy(environment))
    }

    /// Persist an explicit choice, even while an env override is in force —
    /// the override is this run only, and writing through it would leak a
    /// harness run into the next real one.
    public static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }
}
