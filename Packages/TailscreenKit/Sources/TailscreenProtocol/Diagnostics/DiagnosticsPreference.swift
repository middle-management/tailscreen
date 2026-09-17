import Foundation

/// Whether diagnostics recording is on, as a portable decision plus the
/// storage all three apps read it from.
///
/// Same shape as ``ViewerApprovalPreference``, and for the same reasons: a
/// tri-state store so "never touched" is distinguishable from "explicitly
/// turned off", the decision split from the storage so the rules are testable
/// without a `UserDefaults` suite, and an env override for the harnesses.
///
/// ## The default is per channel
///
/// **A release candidate records by default. A shipped release does not.**
///
/// That asymmetry is the whole point. A candidate exists to be tested — the
/// people running one are looking for problems, they have agreed to look for
/// problems, and the entire value of the exercise is lost if the report they
/// send back is "it didn't work" with nothing attached. Recording by default
/// is what makes a candidate a candidate rather than an early release.
///
/// A shipped release is not that. Its users did not sign up to be tested on,
/// so recording there is opt-in, from Settings, when somebody is actually
/// chasing something. Development builds record because the person running one
/// is the person debugging it.
///
/// An explicit choice outranks the channel in every direction: a tester who
/// turns it off stays off when the next candidate is installed, and a release
/// user who turns it on stays on. The channel only answers for people who have
/// never said.
public enum DiagnosticsPreference {

    /// Storage key. One spelling across all three apps.
    public static let defaultsKey = "recordDiagnostics"

    /// Forces the answer for a whole run, either way:
    /// `TAILSCREEN_DIAGNOSTICS=1` on, `=0` off. For the scripted harnesses and
    /// for reproducing a user's setting without changing theirs.
    public static let envKey = "TAILSCREEN_DIAGNOSTICS"

    /// What storage holds. An enum rather than `Bool?` — the third state is a
    /// real state, and naming it stops `unset` from being read as "off" by
    /// anyone skimming.
    public enum Stored: Equatable, Sendable {
        /// Never touched — the channel default applies.
        case unset
        /// An explicit choice, which must survive a channel change.
        case chosen(Bool)
    }

    /// What the environment says, if anything.
    ///
    /// An enum rather than `Bool?` for the same reason ``Stored`` is one: the
    /// third state ("the variable is not set") is a real state and not a
    /// missing answer, and naming it stops `unset` from being read as "off" by
    /// anyone skimming. It is also what swiftlint's `discouraged_optional_boolean`
    /// is pointing at — the enum is the fix, not a workaround for the rule.
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
        // The env override outranks even an explicit choice: it is how a
        // harness pins the behaviour for one run, and a stored preference
        // silently winning would make those runs non-reproducible.
        if case .forced(let value) = override { return value }
        switch stored {
        case .chosen(let value): return value
        case .unset: return channel.recordsDiagnosticsByDefault
        }
    }

    /// What `environment` forces, if anything.
    ///
    /// Only the exact `"1"` and `"0"` count. A stray `TAILSCREEN_DIAGNOSTICS=true`
    /// means nothing rather than something — the same rule
    /// `ViewerApprovalPreference.openDoorForced` applies, because an env var
    /// that quietly reinterprets its value is how a safety default gets lost.
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
        // `object(forKey:)`, not `bool(forKey:)`: the latter reports false for
        // both "absent" and "stored false", which is the distinction the
        // tri-state exists to keep.
        let stored: Stored =
            (defaults.object(forKey: defaultsKey) as? Bool).map(Stored.chosen) ?? .unset
        return resolve(stored: stored, channel: channel, override: forcedBy(environment))
    }

    /// Persist an explicit choice.
    ///
    /// Recording it even while an env override is in force is deliberate — the
    /// override is this run, not a preference change, and writing through it
    /// would let a harness run leak into the next real one.
    public static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }
}
