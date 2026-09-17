import Foundation
import TailscreenProtocol

/// Which build this is.
///
/// The macOS and Windows apps each carry one of these
/// (`Apps/macOS/Sources/BuildInfo.swift`,
/// `Apps/windows/Sources/tailscreen/BuildInfo.swift`); keep the three shaped
/// alike. It deliberately stays a per-app file rather than moving into
/// TailscreenKit: the value is *stamped by CI*, and each platform's workflow
/// rewrites its own copy.
enum BuildInfo {
    /// Short commit SHA. A local `make` build legitimately reads "dev".
    ///
    /// Not yet rewritten by `app-linux.yml` — unlike the macOS and Windows
    /// copies, which their workflows stamp and fail the job over. Until it is,
    /// a Linux build reads `dev`, which makes it a `development` build for
    /// `releaseChannel` below and therefore records diagnostics by default.
    /// That is the safe direction to be wrong in (a tester gets a recording
    /// rather than not getting one), but it does mean a released Linux build
    /// currently records where a released macOS build would not — worth fixing
    /// when the stamping step lands.
    static let commit = "dev"

    /// Marketing version. Same caveat as `commit`.
    static let version = "dev"

    /// Derived, not stamped, so it cannot go stale: SwiftPM defines `DEBUG` in
    /// debug builds and not in release ones.
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

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

    /// Whether this is a shipped release, a candidate for one, or a working
    /// copy — by the same rule `scripts/release-version.sh` uses on the tag.
    static var releaseChannel: ReleaseChannel {
        ReleaseChannel.classify(version: version)
    }

    /// The distro and release, which is the first thing anybody asks about a
    /// capture or portal problem on this platform. Falls back to a bare
    /// "Linux" when `/etc/os-release` is missing or unreadable, which is
    /// normal inside a minimal container.
    static var platform: String {
        guard let text = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return "Linux"
        }
        for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            let value = line.dropFirst("PRETTY_NAME=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return "Linux"
    }

    /// What names this machine in a merged diagnostics bundle.
    static var deviceLabel: String {
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "linux-device" : host
    }

    /// The build and machine facts an exported bundle's header carries.
    static var diagnosticsEnvironment: DiagnosticsEnvironment {
        DiagnosticsEnvironment(
            platform: platform,
            appVersion: version,
            commit: commit,
            configuration: configuration,
            architecture: architecture,
            deviceLabel: deviceLabel)
    }
}
