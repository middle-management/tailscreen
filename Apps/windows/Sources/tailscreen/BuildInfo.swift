import Foundation
import TailscreenProtocol

/// Which build this is. The window footer names the commit and configuration
/// so "I don't see the new counter" and "I'm running yesterday's exe" don't
/// look identical.
enum BuildInfo {
    /// Short commit SHA. **Rewritten by CI** — see the "Stamp the build" step
    /// in .github/workflows/app-windows.yml, which fails the job if the
    /// placeholder survives rather than shipping a binary that lies about
    /// which commit it is.
    static let commit = "dev"

    /// Derived, not stamped, so it cannot go stale: SwiftPM defines `DEBUG`
    /// in debug builds and not in release ones.
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
    /// wrongly classify as a development build and record by default.
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

    /// The marketing name, not the kernel version: Windows 11 still reports
    /// major 10, minor 0 — the break is the BUILD number, 22000.
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
