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
    /// steps in `.github/workflows/release.yml` and
    /// `.github/workflows/pr-notarized-build.yml`, which fail the job if the
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
}
