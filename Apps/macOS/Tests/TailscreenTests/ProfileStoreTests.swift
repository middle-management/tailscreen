import XCTest

@testable import Tailscreen

/// Covers the multi-account profile registry: first-launch migration onto
/// the legacy state dir, unique per-profile directories, active-selection
/// persistence (injected `UserDefaults` suite, mirroring
/// `ViewerAccessPolicyStore`'s tests), the remove-refuses-active/last
/// invariants, identity labeling, and the suffix-at-resolve-time
/// `statePath` contract.
@MainActor
final class ProfileStoreTests: XCTestCase {
    private func makeSuite(_ name: String) -> UserDefaults {
        let suiteName = "ProfileStoreTests-\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testFirstLaunchCreatesLegacyRootedDefaultProfile() {
        let store = ProfileStore(defaults: makeSuite(#function))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].stateDirectory, ProfileStore.legacyStateDirectory)
        XCTAssertEqual(store.activeProfileID, store.profiles[0].id)
        XCTAssertFalse(store.profiles[0].hasSignedIn)
    }

    func testAddProfileGetsUniqueProfilesDirectoryAndIsNotActive() {
        let store = ProfileStore(defaults: makeSuite(#function))
        let first = store.addProfile()
        let second = store.addProfile()
        XCTAssertTrue(first.stateDirectory.hasPrefix("profiles/"))
        XCTAssertTrue(second.stateDirectory.hasPrefix("profiles/"))
        XCTAssertNotEqual(first.stateDirectory, second.stateDirectory)
        // Adding must not steal the active selection — the caller switches
        // explicitly.
        XCTAssertEqual(store.activeProfileID, store.profiles[0].id)
    }

    func testSetActiveSwitchesAndIgnoresUnknownID() {
        let store = ProfileStore(defaults: makeSuite(#function))
        let added = store.addProfile()
        store.setActive(added.id)
        XCTAssertEqual(store.activeProfileID, added.id)
        store.setActive(UUID())
        XCTAssertEqual(store.activeProfileID, added.id, "unknown id must be ignored")
    }

    func testRemoveRefusesActiveAndLastProfile() {
        let store = ProfileStore(defaults: makeSuite(#function))
        XCTAssertNil(store.remove(store.activeProfileID), "active profile must not be removable")
        XCTAssertEqual(store.profiles.count, 1)

        let added = store.addProfile()
        XCTAssertNotNil(store.remove(added.id))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertNil(
            store.remove(store.profiles[0].id),
            "last remaining profile must not be removable (it is also active)")
    }

    func testRemoveReturnsEntryForDiskCleanup() {
        let store = ProfileStore(defaults: makeSuite(#function))
        let added = store.addProfile()
        let removed = store.remove(added.id)
        XCTAssertEqual(removed, added)
        XCTAssertFalse(store.profiles.contains(added))
    }

    func testUpdateActiveIdentityLabelsActiveProfileOnly() {
        let store = ProfileStore(defaults: makeSuite(#function))
        let added = store.addProfile()
        store.updateActiveIdentity(displayName: "Robert", loginName: "robert@github")
        XCTAssertEqual(store.activeProfile.displayName, "Robert")
        XCTAssertEqual(store.activeProfile.loginName, "robert@github")
        XCTAssertTrue(store.activeProfile.hasSignedIn)
        XCTAssertEqual(
            store.profiles.first { $0.id == added.id }?.loginName, "",
            "inactive profile must be untouched")
    }

    func testRoundTripAcrossInstances() {
        let suite = makeSuite(#function)
        let store = ProfileStore(defaults: suite)
        let added = store.addProfile()
        store.setActive(added.id)
        store.updateActiveIdentity(displayName: "Work", loginName: "work@example")

        let reloaded = ProfileStore(defaults: suite)
        XCTAssertEqual(reloaded.profiles, store.profiles)
        XCTAssertEqual(reloaded.activeProfileID, added.id)
    }

    func testStoredActiveIDPointingNowhereFallsBackToFirstProfile() {
        let suite = makeSuite(#function)
        suite.set(UUID().uuidString, forKey: "tailscreenActiveProfileID")
        let store = ProfileStore(defaults: suite)
        XCTAssertEqual(store.activeProfileID, store.profiles[0].id)
    }

    func testCorruptBlobDegradesToDefaultProfile() {
        let suite = makeSuite(#function)
        suite.set(Data("not json".utf8), forKey: "tailscreenProfiles")
        let store = ProfileStore(defaults: suite)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].stateDirectory, ProfileStore.legacyStateDirectory)
    }

    func testStatePathAppendsInstanceSuffixAtResolveTime() {
        let legacy = TailscreenProfile(
            id: UUID(), displayName: "", loginName: "", stateDirectory: "tailscale")
        XCTAssertEqual(
            legacy.statePath(appSupport: URL(fileURLWithPath: "/as"), instanceSuffix: "-2"),
            "/as/Tailscreen/tailscale-2")
        XCTAssertEqual(
            legacy.statePath(appSupport: URL(fileURLWithPath: "/as"), instanceSuffix: ""),
            "/as/Tailscreen/tailscale")

        let modern = TailscreenProfile(
            id: UUID(), displayName: "", loginName: "",
            stateDirectory: "profiles/ABC/tailscale")
        XCTAssertEqual(
            modern.statePath(appSupport: URL(fileURLWithPath: "/as"), instanceSuffix: "-1"),
            "/as/Tailscreen/profiles/ABC/tailscale-1")
    }
}
