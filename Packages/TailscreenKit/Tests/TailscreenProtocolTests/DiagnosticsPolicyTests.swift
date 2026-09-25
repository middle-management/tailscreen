import Foundation
import XCTest

@testable import TailscreenProtocol

/// `ReleaseChannel` + `DiagnosticsPreference` — the "on by default in release
/// candidates" rule. Both wrong answers are silent: a candidate recording
/// nothing, or a stable release recording without consent.
final class DiagnosticsPolicyTests: XCTestCase {

    // MARK: - Channel classification

    /// Mirrors `scripts/test-release-version.sh` so the Swift and bash rules can't drift.
    func testChannelMatchesTheReleaseScriptsRule() {
        XCTAssertEqual(ReleaseChannel.classify(version: "0.10.0"), .stable)
        XCTAssertEqual(ReleaseChannel.classify(version: "0.10.0-rc.1"), .releaseCandidate)
        XCTAssertEqual(ReleaseChannel.classify(version: "0.10.0-rc.10"), .releaseCandidate)
        XCTAssertEqual(ReleaseChannel.classify(version: "1.0.0-beta.1"), .releaseCandidate)
    }

    /// CI thinks in `v0.10.0`, the app reads `0.10.0` — must classify the same.
    func testLeadingVIsTolerated() {
        XCTAssertEqual(ReleaseChannel.classify(version: "v0.10.0"), .stable)
        XCTAssertEqual(ReleaseChannel.classify(version: "v0.10.0-rc.2"), .releaseCandidate)
    }

    /// `dev` is what a local `make build` (or unstamped Info.plist) reads as its version.
    func testNonVersionsAreDevelopment() {
        for version in ["dev", "", "pr-1234", "main", "   "] {
            XCTAssertEqual(
                ReleaseChannel.classify(version: version), .development,
                "\(version.debugDescription) should be a development build")
        }
    }

    // MARK: - The default, per channel

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

    /// An explicit choice must survive a channel change in both directions —
    /// a plain `bool(forKey:)` read can't express that.
    func testExplicitChoiceOutranksTheChannel() {
        XCTAssertFalse(
            DiagnosticsPreference.resolve(stored: .chosen(false), channel: .releaseCandidate))
        XCTAssertTrue(
            DiagnosticsPreference.resolve(stored: .chosen(true), channel: .stable))
    }

    // MARK: - The environment override

    /// Outranks even an explicit choice, so a harness run is reproducible regardless of local storage.
    func testEnvironmentOverrideOutranksEverything() {
        XCTAssertTrue(
            DiagnosticsPreference.resolve(
                stored: .chosen(false), channel: .stable, override: .forced(true)))
        XCTAssertFalse(
            DiagnosticsPreference.resolve(
                stored: .chosen(true), channel: .releaseCandidate, override: .forced(false)))
    }

    /// Only exact `"1"`/`"0"` count — same rule as `ViewerApprovalPreference.openDoorForced`.
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

    /// The override applies at `load` and must not rewrite the stored preference.
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
