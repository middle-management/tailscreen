import Foundation
import TailscreenProtocol

/// Which build this is.
///
/// Exists because of a concrete confusion: a change landed, the artifact was
/// rebuilt, and there was no way to tell from the running app whether the
/// binary on screen contained it. "I don't see the new counter" and "I'm
/// running yesterday's exe" look identical, and every round of that costs a
/// download and a test session.
///
/// So the window footer names the commit and the configuration.
enum BuildInfo {
    /// Short commit SHA. **Rewritten by CI** — see the "Stamp the build" step
    /// in .github/workflows/app-windows.yml, which fails the job if the
    /// placeholder survives rather than shipping a binary that lies about
    /// which commit it is.
    static let commit = "dev"

    /// Derived, not stamped, so it cannot go stale: SwiftPM defines `DEBUG`
    /// in debug builds and not in release ones. Worth showing, because the
    /// difference between the two was an order of magnitude in the capture
    /// pipeline and is exactly the kind of thing that gets misattributed to
    /// the code.
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// `abc1234 release`, or `dev debug` from a local build.
    static var summary: String { "\(commit) \(configuration)" }

    /// Marketing version. **Rewritten by the "Stamp the build" step** in
    /// `.github/workflows/app-windows.yml`, alongside `commit`.
    ///
    /// Load-bearing beyond display: `releaseChannel` reads it to decide
    /// whether diagnostics record by default, so an unstamped release would
    /// classify as a development build and record — contrary to the documented
    /// stable-release opt-in. An empty `version` input means a per-push or PR
    /// build and deliberately leaves this "dev": that is a build under test,
    /// and recording by default is right for it.
    static let version = "dev"

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Whether this is a shipped release, a candidate for one, or a working
    /// copy — by the same rule `scripts/release-version.sh` uses on the tag.
    static var releaseChannel: ReleaseChannel {
        ReleaseChannel.classify(version: version)
    }

    /// What names this machine in a merged diagnostics bundle.
    static var deviceLabel: String {
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "windows-device" : host
    }

    /// The marketing name of the running Windows, which is **not** its kernel
    /// version.
    ///
    /// Windows 11 still reports major 10, minor 0 — the break is the BUILD
    /// number, 22000 — so formatting the version triple names every Windows 11
    /// machine "Windows 10". A reader triaging a platform-specific report would
    /// be told the opposite of the truth by the one field whose entire job is
    /// saying which platform it was.
    static var windowsProductName: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = os.patchVersion
        guard os.majorVersion == 10 else {
            return "Windows \(os.majorVersion).\(os.minorVersion).\(build)"
        }
        return build >= 22000 ? "Windows 11 \(build)" : "Windows 10 \(build)"
    }

    /// The build and machine facts an exported bundle's header carries.
    static var diagnosticsEnvironment: DiagnosticsEnvironment {
        return DiagnosticsEnvironment(
            platform: windowsProductName,
            appVersion: version,
            commit: commit,
            configuration: configuration,
            architecture: architecture,
            deviceLabel: deviceLabel)
    }
}
