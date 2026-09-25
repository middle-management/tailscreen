import Foundation
import TailscreenProtocol

/// Which build this is. Mirrored per-app (macOS, Windows) rather than shared
/// via TailscreenKit, because each platform's CI workflow stamps its own
/// copy.
enum BuildInfo {
    /// Short commit SHA. Rewritten by the "Stamp the build" step in
    /// `.github/workflows/app-linux.yml`, which fails the job if the
    /// placeholder survives. A local `make` build legitimately reads "dev".
    static let commit = "dev"

    /// Marketing version, stamped by the same step. Load-bearing beyond
    /// display: `releaseChannel` reads it to decide whether diagnostics
    /// record by default, so an unstamped build classifies as dev (records)
    /// rather than falsely claiming the stable opt-in.
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

    /// Falls back to bare "Linux" when `/etc/os-release` is missing or
    /// unreadable (normal in a minimal container).
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
