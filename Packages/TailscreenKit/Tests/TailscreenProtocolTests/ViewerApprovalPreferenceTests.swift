import XCTest

@testable import TailscreenProtocol

/// `ViewerApprovalPreference` — the "Require approval for new viewers" gate
/// value pushed into `TailscaleScreenShareServer.setRequireApproval`.
///
/// Every wrong answer here is silent: the server's own default is off, so a
/// preference reading `false` when it should read `true` admits strangers
/// with no error or log line.
final class ViewerApprovalPreferenceTests: XCTestCase {

    // MARK: - The pure decision

    /// A never-touched install gets the gate: read `object(forKey:)`, not `bool(forKey:)`.
    func testUnsetDefaultsOn() {
        XCTAssertTrue(ViewerApprovalPreference.resolve(stored: .unset, openDoor: false))
    }

    /// An explicit opt-out survives the on-by-default rule — `bool(forKey:)`
    /// can't tell "unset" from "chosen false", both read `false`.
    func testStoredChoiceSticks() {
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .chosen(false), openDoor: false))
        XCTAssertTrue(ViewerApprovalPreference.resolve(stored: .chosen(true), openDoor: false))
    }

    /// Open-door mode outranks everything, including a stored `true`, or
    /// scripted harnesses park automated viewers on a prompt nobody answers.
    func testOpenDoorOverridesStoredValue() {
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .chosen(true), openDoor: true))
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .unset, openDoor: true))
        XCTAssertFalse(ViewerApprovalPreference.resolve(stored: .chosen(false), openDoor: true))
    }

    /// Only the exact `"1"` arms open door — `"0"`, `"false"`, or empty must not disarm the gate.
    func testOpenDoorRequiresExactlyOne() {
        XCTAssertTrue(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": "1"]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": "0"]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": "true"]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced(["TAILSCREEN_OPEN_DOOR": ""]))
        XCTAssertFalse(ViewerApprovalPreference.openDoorForced([:]))
    }

    // MARK: - Storage

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

    /// A harness run must not rewrite the user's preference: the env override
    /// applies at `load`, so `save`'s stored value survives.
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
