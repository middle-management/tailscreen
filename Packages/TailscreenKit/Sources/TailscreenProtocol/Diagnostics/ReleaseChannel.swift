import Foundation

/// Which kind of build this is: a shipped release, a candidate for one, or
/// somebody's working copy.
///
/// Mirrors `scripts/release-version.sh`'s SemVer rule (hyphen = pre-release),
/// which `pages.yml` also relies on — **keep the two in sync**;
/// `ReleaseChannelTests` pins the same cases as `scripts/test-release-version.sh`.
public enum ReleaseChannel: String, Sendable, CaseIterable, Codable {
    /// A published release: `v0.10.0` → `0.10.0`.
    case stable
    /// A candidate: any version carrying a pre-release suffix, `0.10.0-rc.2`.
    case releaseCandidate
    /// Not a released build at all — a local `make build`, a PR artifact, a
    /// binary with no version stamped into it.
    case development

    /// Classify a marketing version string (no leading `v`). A hyphen makes
    /// it a candidate; a non-digit lead (`dev`, a branch name, empty) is
    /// `.development`; anything else is stable.
    public static func classify(version: String) -> ReleaseChannel {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a leading `v`: callers pass either a tag or a version.
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
