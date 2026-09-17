import Foundation

/// Which kind of build this is: a shipped release, a candidate for one, or
/// somebody's working copy.
///
/// Exists because "on by default in release candidates" needs one answer to
/// "is this a release candidate", and the repo already has that rule — it is
/// just written in bash. `scripts/release-version.sh` derives `prerelease`
/// from the tag with exactly one test:
///
/// > SemVer: a hyphen after the version IS the pre-release marker.
///
/// and `pages.yml`'s tag filter uses the same one, deliberately, because (its
/// words) one definition of "pre-release" across the repo beats two that agree
/// until they don't. This is that definition in Swift, for the runtime side of
/// the same question. **If the bash rule changes, change this with it** —
/// `ReleaseChannelTests` pins the cases the script's own test
/// (`scripts/test-release-version.sh`) pins, so the two stay honest.
public enum ReleaseChannel: String, Sendable, CaseIterable, Codable {
    /// A published release: `v0.10.0` → `0.10.0`.
    case stable
    /// A candidate: any version carrying a pre-release suffix, `0.10.0-rc.2`.
    case releaseCandidate
    /// Not a released build at all — a local `make build`, a PR artifact, a
    /// binary with no version stamped into it.
    case development

    /// Classify a marketing version string (no leading `v`).
    ///
    /// Three rules, matching the script:
    ///
    ///   * A hyphen makes it a candidate — `0.10.0-rc.2`, `1.0.0-beta.1`.
    ///   * Something that does not start with digits is not a version at all
    ///     (`dev`, a branch name, an empty Info.plist) and is a development
    ///     build. The script reaches the same conclusion by a different route:
    ///     it calls those pre-releases so packaging never lands on the stable
    ///     identity. Same instinct — when in doubt, not stable — but this side
    ///     can name the case properly, and it matters here because a developer
    ///     and a tester want different defaults from a shipped build.
    ///   * Anything else is stable.
    public static func classify(version: String) -> ReleaseChannel {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a leading `v` so a caller can pass a tag or a version and
        // get the same answer; the app reads the latter, CI thinks in the
        // former, and the difference has caused enough bugs elsewhere.
        let version = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard let first = version.first, first.isNumber else { return .development }
        return version.contains("-") ? .releaseCandidate : .stable
    }

    /// Whether diagnostics recording starts on in this channel when the user
    /// has expressed no preference. See ``DiagnosticsPreference``.
    public var recordsDiagnosticsByDefault: Bool {
        switch self {
        case .stable: return false
        case .releaseCandidate, .development: return true
        }
    }
}
