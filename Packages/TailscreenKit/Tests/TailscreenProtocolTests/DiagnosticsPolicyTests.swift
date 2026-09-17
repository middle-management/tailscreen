import Foundation
import XCTest

@testable import TailscreenProtocol

/// `ReleaseChannel` + `DiagnosticsPreference` — the "on by default in release
/// candidates" rule.
///
/// This is the requirement the feature was asked for, so it is pinned
/// directly rather than left to be inferred from the app's behaviour. Both
/// wrong answers are quiet: a candidate that records nothing produces the
/// "it didn't work" report the feature exists to prevent, and a stable release
/// that records by default is collecting from people who never agreed to it.
final class DiagnosticsPolicyTests: XCTestCase {

    // MARK: - Channel classification

    /// The same cases `scripts/test-release-version.sh` pins, so the Swift
    /// rule and the bash rule cannot drift.
    func testChannelMatchesTheReleaseScriptsRule() {
        XCTAssertEqual(ReleaseChannel.classify(version: "0.10.0"), .stable)
        XCTAssertEqual(ReleaseChannel.classify(version: "0.10.0-rc.1"), .releaseCandidate)
        XCTAssertEqual(ReleaseChannel.classify(version: "0.10.0-rc.10"), .releaseCandidate)
        XCTAssertEqual(ReleaseChannel.classify(version: "1.0.0-beta.1"), .releaseCandidate)
    }

    /// A tag and a version must classify the same. CI thinks in `v0.10.0`,
    /// the app reads `0.10.0`, and the difference has caused bugs elsewhere
    /// in this repo.
    func testLeadingVIsTolerated() {
        XCTAssertEqual(ReleaseChannel.classify(version: "v0.10.0"), .stable)
        XCTAssertEqual(ReleaseChannel.classify(version: "v0.10.0-rc.2"), .releaseCandidate)
    }

    /// Anything that is not a version is a development build — `dev` is what
    /// `BuildInfo.commit` reads from a local `make build`, and an unstamped
    /// Info.plist produces the same.
    func testNonVersionsAreDevelopment() {
        for version in ["dev", "", "pr-1234", "main", "   "] {
            XCTAssertEqual(
                ReleaseChannel.classify(version: version), .development,
                "\(version.debugDescription) should be a development build")
        }
    }

    // MARK: - The default, per channel

    /// The requirement, stated once: candidates record, releases do not.
    func testDefaultIsOnForCandidatesAndOffForReleases() {
        XCTAssertTrue(
            DiagnosticsPreference.resolve(stored: .unset, channel: .releaseCandidate),
            "a release candidate must record by default")
        XCTAssertFalse(
            DiagnosticsPreference.resolve(stored: .unset, channel: .stable),
            "a shipped release must not record unless asked")
        XCTAssertTrue(
            DiagnosticsPreference.resolve(stored: .unset, channel: .development),
            "a developer running their own build wants the record")
    }

    /// An explicit choice survives a channel change in BOTH directions. A
    /// tester who turned it off must stay off when the next candidate lands,
    /// and a release user who turned it on must stay on. A plain
    /// `bool(forKey:)` read cannot express the first case at all.
    func testExplicitChoiceOutranksTheChannel() {
        XCTAssertFalse(
            DiagnosticsPreference.resolve(stored: .chosen(false), channel: .releaseCandidate))
        XCTAssertTrue(
            DiagnosticsPreference.resolve(stored: .chosen(true), channel: .stable))
    }

    // MARK: - The environment override

    /// The override outranks even an explicit choice, so a harness run is
    /// reproducible regardless of what is stored on the machine running it.
    func testEnvironmentOverrideOutranksEverything() {
        XCTAssertTrue(
            DiagnosticsPreference.resolve(
                stored: .chosen(false), channel: .stable, override: .forced(true)))
        XCTAssertFalse(
            DiagnosticsPreference.resolve(
                stored: .chosen(true), channel: .releaseCandidate, override: .forced(false)))
    }

    /// Only the exact `"1"` and `"0"` count. An env var that quietly
    /// reinterprets its value is how a safety default gets lost — the same
    /// rule `ViewerApprovalPreference.openDoorForced` applies.
    func testOverrideRequiresExactlyOneOrZero() {
        XCTAssertEqual(
            DiagnosticsPreference.forcedBy(["TAILSCREEN_DIAGNOSTICS": "1"]), .forced(true))
        XCTAssertEqual(
            DiagnosticsPreference.forcedBy(["TAILSCREEN_DIAGNOSTICS": "0"]), .forced(false))
        XCTAssertEqual(
            DiagnosticsPreference.forcedBy(["TAILSCREEN_DIAGNOSTICS": "true"]), .unset)
        XCTAssertEqual(DiagnosticsPreference.forcedBy(["TAILSCREEN_DIAGNOSTICS": "yes"]), .unset)
        XCTAssertEqual(DiagnosticsPreference.forcedBy(["TAILSCREEN_DIAGNOSTICS": ""]), .unset)
        XCTAssertEqual(DiagnosticsPreference.forcedBy([:]), .unset)
    }

    // MARK: - Storage

    /// Round-trip through an injected suite, including the unset case reading
    /// the channel default off real storage rather than only off the pure
    /// function.
    func testPersistenceRoundTrip() throws {
        let suiteName = "DiagnosticsPreferenceTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            DiagnosticsPreference.load(
                defaults: suite, channel: .releaseCandidate, environment: [:]))
        XCTAssertFalse(
            DiagnosticsPreference.load(defaults: suite, channel: .stable, environment: [:]))

        DiagnosticsPreference.save(false, defaults: suite)
        XCTAssertFalse(
            DiagnosticsPreference.load(
                defaults: suite, channel: .releaseCandidate, environment: [:]),
            "an opt-out must survive into the next candidate")

        DiagnosticsPreference.save(true, defaults: suite)
        XCTAssertTrue(
            DiagnosticsPreference.load(defaults: suite, channel: .stable, environment: [:]))
    }

    /// A harness run must not rewrite the user's preference: the override
    /// applies at `load`, so the stored choice is still there afterwards.
    func testOverrideDoesNotClobberTheStoredChoice() throws {
        let suiteName = "DiagnosticsPreferenceTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        DiagnosticsPreference.save(true, defaults: suite)
        let forcedOff = ["TAILSCREEN_DIAGNOSTICS": "0"]
        XCTAssertFalse(
            DiagnosticsPreference.load(
                defaults: suite, channel: .stable, environment: forcedOff))
        XCTAssertTrue(
            DiagnosticsPreference.load(defaults: suite, channel: .stable, environment: [:]))
    }
}
