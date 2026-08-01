import Foundation

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
    /// in .github/workflows/windows-build.yml, which fails the job if the
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
}
