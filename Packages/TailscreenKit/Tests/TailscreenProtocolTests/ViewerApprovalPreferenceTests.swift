import XCTest

@testable import TailscreenProtocol

/// `ViewerApprovalPreference` — the "Require approval for new viewers" gate
/// value the GTK and Windows apps push into
/// `TailscaleScreenShareServer.setRequireApproval`.
///
/// Worth pinning because every wrong answer here is silent: the server's own
/// default is off, so a preference that reads `false` when it should read
/// `true` produces a share that works perfectly and admits strangers. There is
/// no error and no log line — the only symptom is that the Accept/Deny prompt
/// never appears, which looks like nobody has connected.
final class ViewerApprovalPreferenceTests: XCTestCase {

    // MARK: - The pure decision

    /// A never-touched install gets the gate. This is the whole point of
    /// reading `object(forKey:)` instead of `bool(forKey:)`.
    func testUnsetDefaultsOn() {
        XCTAssertTrue(ViewerApprovalPreference.resolve(stored: .unset, openDoor: false))
    }

    /// An explicit opt-out survives the on-by-default rule. A `bool(forKey:)`
    /// read cannot tell this case from the one above — both are `false` — so
    /// flipping the default on would silently re-enable the gate for everyone
    /// who had turned it off.
    func testStoredChoiceSticks() {
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .chosen(false), openDoor: false))
        XCTAssertTrue(ViewerApprovalPreference.resolve(stored: .chosen(true), openDoor: false))
    }

    /// Open-door mode outranks everything, including a stored `true`.
    /// Otherwise the scripted harnesses park their automated viewers on a
    /// prompt nobody is there to answer.
    func testOpenDoorOverridesStoredValue() {
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .chosen(true), openDoor: true))
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .unset, openDoor: true))
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .chosen(false), openDoor: true))
    }

    /// Only the exact `"1"` arms open door. A stray `TAILSCREEN_OPEN_DOOR=0`
    /// (or `false`, or empty) must not disarm the gate — an env var that means
    /// "off" when set to "0" is the classic way a safety default is lost.
    func testOpenDoorRequiresExactlyOne() {
        XCTAssertTrue(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": "1"]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": "0"]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": "true"]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": ""]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced([:]))
    }

    // MARK: - Storage

    /// Round-trip through an injected suite, and the unset case reading `true`
    /// off real storage rather than only off the pure function.
    func testPersistenceRoundTrip() throws {
        let suiteName = "ViewerApprovalPreferenceTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ViewerApprovalPreference.load(defaults: suite, environment: [:]))

        ViewerApprovalPreference.save(false, defaults: suite)
        XCTAssertFalse(ViewerApprovalPreference.load(defaults: suite, environment: [:]))

        ViewerApprovalPreference.save(true, defaults: suite)
        XCTAssertTrue(ViewerApprovalPreference.load(defaults: suite, environment: [:]))
    }

    /// A harness run must not rewrite the user's preference. `save` records
    /// what the user chose; the env override is applied at `load`, so the
    /// stored `true` is still there once the harness env goes away.
    func testOpenDoorDoesNotClobberTheStoredChoice() throws {
        let suiteName = "ViewerApprovalPreferenceTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        ViewerApprovalPreference.save(true, defaults: suite)
        let openDoor = ["TAILSCREEN_OPEN_DOOR": "1"]
        XCTAssertFalse(ViewerApprovalPreference.load(defaults: suite, environment: openDoor))
        XCTAssertTrue(ViewerApprovalPreference.load(defaults: suite, environment: [:]))
    }
}
