import Foundation

/// Which build this is.
///
/// The macOS app had no such stamp anywhere in its UI. A released `.app`
/// names a marketing version in its Info.plist, but a locally built binary
/// or a PR-notarized test build names nothing at all — and "I don't see the
/// fix" and "I'm running last week's build" look identical from the outside.
/// Every round of that costs a download and a test session, so Settings →
/// About shows the answer instead of asking for another build.
///
/// The Windows app carries the same type for the same reason
/// (`Apps/windows/Sources/tailscreen/BuildInfo.swift`); keep the two shaped
/// alike. It deliberately stays a per-app file rather than moving into
/// TailscreenKit: the value is *stamped by CI*, and each platform's workflow
/// rewrites its own copy.
enum BuildInfo {
    /// Short commit SHA. **Rewritten by CI** — see the "Stamp the build"
    /// step in `.github/workflows/app-macos.yml` (the shared definition both
    /// the release and the notarized PR build call), which fails the job if the
    /// placeholder survives rather than shipping an app that lies about
    /// which commit it is. A local `make build` legitimately reads "dev".
    static let commit = "dev"

    /// Derived, not stamped, so it cannot go stale: SwiftPM defines `DEBUG`
    /// in debug builds and not in release ones. Worth showing, because the
    /// two differ by a wide margin in the capture/encode path and that gap
    /// is exactly the kind of thing that gets misattributed to the code.
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Which slice of the universal binary is actually executing. On Apple
    /// silicon this is the Rosetta question: an x86_64 slice under
    /// translation performs nothing like the arm64 one, and nothing else in
    /// the UI would ever hint at the difference.
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

    /// Marketing version from the bundle, or `dev` for a binary built without
    /// an Info.plist (a local `make build`, which runs the executable
    /// directly).
    static var marketingVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Whether this is a shipped release, a candidate for one, or a working
    /// copy — derived from ``marketingVersion`` by the same rule
    /// `scripts/release-version.sh` uses on the tag.
    ///
    /// Read by `DiagnosticsPreference` to decide whether diagnostics recording
    /// starts on: a candidate exists to be tested and records by default, a
    /// shipped release does not. That is the one place a wrong answer here is
    /// user-visible, so it is worth knowing that an *unstamped* build reads as
    /// `development` and therefore records — which is right for the person
    /// running their own build, and is also what every `swift run` does.
    static var releaseChannel: ReleaseChannel {
        // An explicit marker beats inferring from the version, and for macOS
        // it is the only thing that works: a PR artifact is stamped
        // `0.0.<PR>` because CFBundleShortVersionString must be numeric, and
        // that parses as a perfectly ordinary stable release. Inferring alone
        // therefore turned diagnostics OFF for exactly the builds testers are
        // handed, which is the opposite of the intent.
        if let overridden = ReleaseChannel(rawValue: channelOverride) { return overridden }
        return ReleaseChannel.classify(version: marketingVersion)
    }

    /// Set by CI for a build it knows is not a release — today, a PR artifact.
    ///
    /// **Rewritten by the "Stamp the build" step** in
    /// `.github/workflows/app-macos.yml`, which fills it in whenever the build
    /// carries a `label` (the PR-artifact path) and leaves it empty for a real
    /// release. Empty means "no opinion — classify from the version", which is
    /// what a local build and a tagged release both want.
    static let channelOverride = ""
}
