import Foundation
import XCTest

@testable import TailscreenProtocol

/// Covers the shared multi-account registry both swift-cross-ui hosts use:
/// first-launch seeding (with and without a directory to adopt), the two
/// migration paths, unique per-profile state dirs, active-selection
/// persistence, the remove-refuses-active/last invariants, corrupt-blob
/// degradation, and the two platform layouts — including the Windows one,
/// which no Windows machine is needed to check because the layout is a pure
/// string derivation.
final class AccountProfileStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AccountProfileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    private func path(_ component: String) -> String {
        scratch.appendingPathComponent(component).path
    }

    // MARK: First launch

    func testFirstLaunchSeedsOneProfileUnderTheProfilesSubtree() {
        let root = path("root")
        let store = AccountProfileStore(layout: AccountProfileLayout(root: root))

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.activeID, store.profiles[0].id)
        XCTAssertEqual(store.active.name, "Account 1")
        XCTAssertEqual(
            store.profiles[0].statePath, root + "/profiles/" + store.profiles[0].id,
            "a fresh profile's state dir is invented under the registry root")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root + "/profiles.json"),
            "the seed must be persisted immediately, not only on first mutation")
    }

    /// The Windows upgrade path: the pre-registry build kept its node state in
    /// one fixed directory. Account #1 must BE that directory, or the upgrade
    /// silently signs everyone out.
    func testSeedStatePathAdoptsThePreRegistryStateDirectory() throws {
        let root = path("Tailscreen")
        let legacyState = root + "/tailscale"
        try FileManager.default.createDirectory(
            atPath: legacyState, withIntermediateDirectories: true)
        try Data("machine-key".utf8).write(to: URL(fileURLWithPath: legacyState + "/tailscaled.state"))

        let store = AccountProfileStore(
            layout: AccountProfileLayout(root: root, seedStatePath: legacyState))

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.active.statePath, legacyState)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyState + "/tailscaled.state"),
            "adopting must never move or delete the existing node state")
    }

    /// Adoption is unconditional, so a first run that never logs in and the
    /// run after it agree on the directory. (Conditioning it on the directory
    /// existing would give run #1 a `profiles/<uuid>` dir and run #2 nothing
    /// to find.)
    func testSeedStatePathIsAdoptedEvenWhenTheDirectoryDoesNotExistYet() {
        let root = path("Tailscreen")
        let store = AccountProfileStore(
            layout: AccountProfileLayout(root: root, seedStatePath: root + "/tailscale"))
        XCTAssertEqual(store.active.statePath, root + "/tailscale")
    }

    // MARK: Adding, switching, renaming

    func testAddedProfilesGetUniqueDirectoriesAndBecomeActive() {
        let root = path("root")
        let store = AccountProfileStore(layout: AccountProfileLayout(root: root))
        let seeded = store.active

        let second = store.addProfile()
        let third = store.addProfile()

        XCTAssertEqual(store.profiles.count, 3)
        XCTAssertEqual(Set([seeded.statePath, second.statePath, third.statePath]).count, 3)
        XCTAssertTrue(second.statePath.hasPrefix(root + "/profiles/"))
        XCTAssertTrue(third.statePath.hasPrefix(root + "/profiles/"))
        XCTAssertEqual(second.name, "Account 2")
        XCTAssertEqual(third.name, "Account 3")
        // Adding an account is a request to USE it — unlike the macOS store,
        // whose menu switches separately.
        XCTAssertEqual(store.activeID, third.id)
    }

    func testSetActiveSwitchesAndReportsWhetherItChangedAnything() {
        let store = AccountProfileStore(layout: AccountProfileLayout(root: path("root")))
        let seeded = store.active
        let added = store.addProfile()

        XCTAssertFalse(store.setActive(added.id), "already active")
        XCTAssertTrue(store.setActive(seeded.id))
        XCTAssertEqual(store.activeID, seeded.id)
        XCTAssertFalse(store.setActive("no-such-profile"), "unknown ids are ignored")
        XCTAssertEqual(store.activeID, seeded.id)
    }

    func testRenameOnlyReportsRealChanges() {
        let store = AccountProfileStore(layout: AccountProfileLayout(root: path("root")))
        let id = store.activeID

        XCTAssertTrue(store.rename(id, to: "robert@github"))
        XCTAssertEqual(store.active.name, "robert@github")
        XCTAssertFalse(store.rename(id, to: "robert@github"), "unchanged name is a no-op")
        XCTAssertFalse(store.rename(id, to: ""), "empty name is refused")
        XCTAssertFalse(store.rename("no-such-profile", to: "x"))
        XCTAssertEqual(store.active.name, "robert@github")
    }

    // MARK: Removal invariants

    func testRemoveRefusesTheActiveAndTheLastProfile() {
        let store = AccountProfileStore(layout: AccountProfileLayout(root: path("root")))
        let seeded = store.active

        XCTAssertNil(store.remove(seeded.id), "the active profile is not removable")
        XCTAssertEqual(store.profiles.count, 1)

        let added = store.addProfile()  // becomes active
        let removed = store.remove(seeded.id)
        XCTAssertEqual(removed, seeded, "the entry comes back so its state dir can be deleted")
        XCTAssertEqual(store.profiles.map(\.id), [added.id])
        XCTAssertNil(
            store.remove(added.id),
            "the last remaining profile is not removable (it is also active)")
    }

    // MARK: Persistence

    func testSelectionAndProfilesSurviveAcrossInstances() {
        let layout = AccountProfileLayout(root: path("root"))
        let store = AccountProfileStore(layout: layout)
        let seeded = store.active
        let added = store.addProfile()
        store.rename(added.id, to: "work@example.com")
        store.setActive(seeded.id)

        let reloaded = AccountProfileStore(layout: layout)
        XCTAssertEqual(reloaded.profiles, store.profiles)
        XCTAssertEqual(reloaded.activeID, seeded.id)
        XCTAssertEqual(reloaded.profiles.first { $0.id == added.id }?.name, "work@example.com")
    }

    func testStoredActiveIDPointingNowhereFallsBackToTheFirstProfile() throws {
        let root = path("root")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let blob = """
            {"profiles":[{"id":"a","name":"A","statePath":"\(root)/profiles/a"},\
            {"id":"b","name":"B","statePath":"\(root)/profiles/b"}],"activeID":"gone"}
            """
        try Data(blob.utf8).write(to: URL(fileURLWithPath: root + "/profiles.json"))

        let store = AccountProfileStore(layout: AccountProfileLayout(root: root))
        XCTAssertEqual(store.activeID, "a")
    }

    func testCorruptBlobDegradesToASeededProfileKeepingTheAdoptedLogin() throws {
        let root = path("Tailscreen")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: root + "/profiles.json"))

        let store = AccountProfileStore(
            layout: AccountProfileLayout(root: root, seedStatePath: root + "/tailscale"))

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(
            store.active.statePath, root + "/tailscale",
            "a corrupt registry must not orphan the login that is still on disk")
    }

    func testEmptyProfileListInAValidBlobIsTreatedAsNoRegistry() throws {
        let root = path("root")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data(#"{"profiles":[],"activeID":""}"#.utf8)
            .write(to: URL(fileURLWithPath: root + "/profiles.json"))

        let store = AccountProfileStore(layout: AccountProfileLayout(root: root))
        XCTAssertEqual(store.profiles.count, 1, "the never-empty invariant holds")
        XCTAssertEqual(store.activeID, store.profiles[0].id)
    }

    // MARK: Layouts

    func testXDGLayoutPrefersXDGConfigHomeThenHome() {
        let xdg = AccountProfileLayout.xdg(environment: [
            "XDG_CONFIG_HOME": "/x/config", "HOME": "/home/robert"
        ])
        XCTAssertEqual(xdg.root, "/x/config/tailscreen")
        XCTAssertNil(xdg.seedStatePath, "this host never kept state outside the registry root")

        let home = AccountProfileLayout.xdg(environment: ["HOME": "/home/robert"])
        XCTAssertEqual(home.root, "/home/robert/.config/tailscreen")

        let empty = AccountProfileLayout.xdg(
            environment: ["XDG_CONFIG_HOME": ""], fallbackDirectory: "/cwd")
        XCTAssertEqual(empty.root, "/cwd/tailscreen", "an empty XDG value is not a value")
    }

    /// The Windows layout, checked on Linux: it is pure string derivation, and
    /// the seed must be the `%LOCALAPPDATA%\Tailscreen\tailscale` directory the
    /// single-account build used.
    func testWindowsLayoutRootsUnderLocalAppDataAndSeedsTheOldStateDirectory() throws {
        // Asserted with a POSIX base so the exact strings are checkable here:
        // Foundation on Linux resolves a `C:\…` base against the CWD, which no
        // Windows build does. What the derivation itself is — `URL`
        // path-appending — is platform-independent, and the shape below is
        // what the Windows build produces from the same code.
        let layout = AccountProfileLayout.windowsLocalAppData(
            environment: ["LOCALAPPDATA": "/local-app-data"])
        XCTAssertEqual(layout.root, "/local-app-data/Tailscreen")

        // The migration contract, spelled out: the seed is byte-for-byte the
        // expression the pre-registry `AppUIState.stateDirectory()` used for
        // its one fixed state dir. If this drifts, upgrading signs users out.
        let preRegistry = URL(fileURLWithPath: "/local-app-data")
            .appendingPathComponent("Tailscreen")
            .appendingPathComponent("tailscale")
            .path
        XCTAssertEqual(layout.seedStatePath, preRegistry)

        // And the invariant that survives any base or separator: the seed is
        // the root's `tailscale` child.
        let windowsish = AccountProfileLayout.windowsLocalAppData(
            environment: ["LOCALAPPDATA": #"C:\Users\robert\AppData\Local"#])
        let seed = try XCTUnwrap(windowsish.seedStatePath)
        XCTAssertTrue(windowsish.root.hasSuffix("Tailscreen"))
        XCTAssertTrue(seed.hasPrefix(windowsish.root))
        XCTAssertTrue(seed.hasSuffix("tailscale"))

        let fallback = AccountProfileLayout.windowsLocalAppData(
            environment: [:], fallbackDirectory: "/fallback")
        XCTAssertEqual(fallback.root, "/fallback/Tailscreen")
    }

    /// A registry written by the GTK build that predates this type must load
    /// unchanged — same file name, same keys, same shape.
    func testExistingOnDiskRegistryFormatStillDecodes() throws {
        let root = path("tailscreen")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let blob = """
            {"profiles":[\
            {"id":"A1","name":"Account 1","statePath":"\(root)/profiles/A1"},\
            {"id":"A2","name":"work@example.com","statePath":"\(root)/profiles/A2"}],\
            "activeID":"A2"}
            """
        try Data(blob.utf8).write(to: URL(fileURLWithPath: root + "/profiles.json"))

        let store = AccountProfileStore(layout: AccountProfileLayout(root: root))
        XCTAssertEqual(store.profiles.map(\.id), ["A1", "A2"])
        XCTAssertEqual(store.activeID, "A2")
        XCTAssertEqual(store.active.name, "work@example.com")
    }
}
