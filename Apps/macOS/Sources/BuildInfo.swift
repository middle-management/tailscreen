import Foundation

/// Which build this is, shown at Settings → About so a bug report can be
/// pinned to an exact commit/config/arch instead of guessing.
///
/// Windows carries the same type (`Apps/windows/Sources/tailscreen/BuildInfo.swift`),
/// kept shaped alike. Stays per-app rather than in TailscreenKit because each
/// platform's CI workflow stamps its own copy.
enum BuildInfo {
    /// Short commit SHA. **Rewritten by CI** — see the "Stamp the build" step
    /// in `.github/workflows/app-macos.yml`, which fails the job if the
    /// placeholder survives. A local `make build` legitimately reads "dev".
    static let commit = "dev"

    /// Derived, not stamped: SwiftPM defines `DEBUG` in debug builds only.
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Which slice of the universal binary is executing — distinguishes a
    /// native arm64 run from an x86_64 slice under Rosetta translation.
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// `abc1234 release`, or `dev debug` from a local build.
    static var summary: String { "\(commit) \(configuration)" }

    /// Marketing version from the bundle, or `dev` for a binary with no
    /// Info.plist (e.g. `make build`, which runs the executable directly).
    static var marketingVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Shipped release, RC, or working copy — derived from ``marketingVersion``
    /// by the same rule `scripts/release-version.sh` uses on the tag. Drives
    /// `DiagnosticsPreference`'s default (on for a candidate, off for a
    /// shipped release; an unstamped build reads `development` and records).
    static var releaseChannel: ReleaseChannel {
        // channelOverride beats inference: a PR artifact is stamped
        // `0.0.<PR>` (CFBundleShortVersionString must be numeric), which
        // would otherwise parse as an ordinary stable release.
        if let overridden = ReleaseChannel(rawValue: channelOverride) { return overridden }
        return ReleaseChannel.classify(version: marketingVersion)
    }

    /// Set by CI's "Stamp the build" step for a build known not to be a
    /// release (today, a PR artifact); empty means "classify from the version".
    static let channelOverride = ""
}
