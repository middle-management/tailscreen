import TailscreenProtocol
import XCTest

@testable import WinNotifyKit

/// `WindowsNotifier` — what gets handed to the notification platform.
///
/// **Read this before trusting the coverage.** There is no
/// `AppNotificationManager` off Windows and nothing stands in for one, exactly
/// as `WASAPIKit` documents for its own Linux leg. Nothing here posts a toast,
/// sees a toast, or presses a button. What it does cover is the layer between
/// the host and the shim — which scenario, which tag, which priority, and
/// whether an unregistered notifier degrades quietly — through the
/// `deliverForTesting` seam, because those are the decisions a Windows runner
/// would not check either: a wrong tag and a right tag both post.
///
/// The payload itself is pinned in `WindowsToastPayloadTests`, on the same CI.
final class WindowsNotifierTests: XCTestCase {

    private let approve = WindowsNotifier.Button(key: "approve", label: "Accept")
    private let deny = WindowsNotifier.Button(key: "deny", label: "Deny")

    /// Captures one delivery.
    private struct Delivered {
        var payload = ""
        var tag = ""
        var group = ""
        var highPriority = false
    }

    private func notifier(
        supportsUrgent: Bool = true, id: UInt32 = 7, into box: Box<Delivered?>
    ) -> WindowsNotifier {
        let notifier = WindowsNotifier(testingWith: supportsUrgent)
        notifier.deliverForTesting = { payload, tag, group, high in
            box.value = Delivered(payload: payload, tag: tag, group: group, highPriority: high)
            return id
        }
        return notifier
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Platform

    /// Off Windows there is no platform, and the wrapper must say so rather
    /// than pretend. Linux CI runs this leg; a Windows runner runs the other.
    func testPlatformSupportMatchesTheBuild() {
        #if os(Windows)
        XCTAssertTrue(WindowsNotifier.isSupported)
        #else
        XCTAssertFalse(WindowsNotifier.isSupported)
        XCTAssertNil(WindowsNotifier(displayName: "Tailscreen"))
        #endif
    }

    /// The state this whole design turns on: a notifier that could not register
    /// is not an error, it is a notifier that posts nothing. The host keeps its
    /// in-window prompts.
    func testUnregisteredNotifierPostsNothingAndDoesNotCrash() {
        let notifier = WindowsNotifier(testingWith: true)

        XCTAssertNil(notifier.post(summary: "s", body: "b", identity: "id"))
        XCTAssertEqual(notifier.setting, .unknown)
        XCTAssertFalse(notifier.canBeSeen)
        XCTAssertNil(notifier.lastError)
        notifier.withdraw("anything")
        notifier.withdrawAll()
    }

    /// `unknown` is not `unsupported`: one is "the query failed", the other is
    /// the platform's own answer, and only the second is worth telling a user
    /// about.
    func testSettingEnumCoversThePlatformValues() {
        XCTAssertEqual(WindowsNotifier.Setting(rawValue: 0), .enabled)
        XCTAssertEqual(WindowsNotifier.Setting(rawValue: 5), .unsupported)
        XCTAssertEqual(WindowsNotifier.Setting(rawValue: 6), .unknown)
        XCTAssertNil(WindowsNotifier.Setting(rawValue: 7))
        XCTAssertEqual(WindowsNotifier.Setting.allCases.count, 7)
    }

    /// Only `enabled` means a toast will be seen. Every other value posts
    /// successfully into nothing, which is why the share card has to say so.
    func testOnlyEnabledCountsAsVisible() {
        for setting in WindowsNotifier.Setting.allCases where setting != .enabled {
            XCTAssertNotEqual(setting, .enabled, "\(setting) must not read as visible")
        }
    }

    // MARK: - Composition

    func testPostComposesThePayloadAndReturnsTheTag() {
        let box = Box<Delivered?>(nil)
        let tag = notifier(into: box).post(
            summary: "Someone wants to watch",
            body: "wisp is waiting to be let in.",
            buttons: [approve, deny],
            identity: "viewerPending:100.64.0.1",
            blocksSomeone: true)

        XCTAssertEqual(tag, "viewerPending:100.64.0.1")
        XCTAssertEqual(box.value?.tag, tag)
        XCTAssertEqual(box.value?.group, WindowsToastPayload.group)
        XCTAssertTrue(box.value?.payload.contains("<text>Someone wants to watch</text>") == true)
        XCTAssertTrue(box.value?.payload.contains("content=\"Accept\"") == true)
    }

    /// A platform that refused the post must not hand back a tag: the caller
    /// would store it and later withdraw a notification that never existed,
    /// leaving the real one on screen forever.
    func testRefusedPostReturnsNil() {
        let box = Box<Delivered?>(nil)
        XCTAssertNil(
            notifier(id: 0, into: box).post(summary: "s", body: "b", identity: "id"))
    }

    /// The tag is a pure function of the identity, so a re-post replaces the
    /// banner in place instead of stacking a second one — Windows' spelling of
    /// `replaces_id`.
    func testRepostingTheSameIdentityReusesTheTag() {
        let box = Box<Delivered?>(nil)
        let notifier = notifier(into: box)

        let first = notifier.post(summary: "a", identity: "controlRequested:100.64.0.9")
        let second = notifier.post(summary: "b", identity: "controlRequested:100.64.0.9")

        XCTAssertEqual(first, second)
    }

    /// Two axes, spent on the same narrow set: `scenario` is about display and
    /// `AppNotificationPriority` is about delivery under battery saver.
    func testOnlyBlockingNoticesGetHighPriorityAndUrgentScenario() {
        let blocking = Box<Delivered?>(nil)
        _ = notifier(into: blocking).post(
            summary: "s", buttons: [approve], identity: "id", blocksSomeone: true)

        XCTAssertEqual(blocking.value?.highPriority, true)
        XCTAssertTrue(blocking.value?.payload.contains("scenario=\"urgent\"") == true)

        let invitation = Box<Delivered?>(nil)
        _ = notifier(into: invitation).post(
            summary: "s", buttons: [approve], identity: "id", blocksSomeone: false)

        XCTAssertEqual(invitation.value?.highPriority, false)
        XCTAssertTrue(invitation.value?.payload.contains("scenario=\"reminder\"") == true)
    }

    /// The capability degradation that has no error attached to it: emitting
    /// `urgent` on Windows 10 is a schema violation, so nothing would be posted
    /// at all. `reminder` is what every build understands.
    func testWindows10DowngradesRatherThanPostingNothing() {
        let box = Box<Delivered?>(nil)
        _ = notifier(supportsUrgent: false, into: box).post(
            summary: "s", buttons: [approve], identity: "id", blocksSomeone: true)

        XCTAssertTrue(box.value?.payload.contains("scenario=\"reminder\"") == true)
        XCTAssertFalse(box.value?.payload.contains("urgent") == true)
        // Still high priority: the delivery axis is not the one Windows 10 is
        // missing, and dropping it too would degrade further than it has to.
        XCTAssertEqual(box.value?.highPriority, true)
    }

    /// A report has nothing to answer, so it expires like any other banner.
    func testInformationalNoticesGetNoScenario() {
        let box = Box<Delivered?>(nil)
        _ = notifier(into: box).post(
            summary: "Viewer left", body: "wisp stopped watching.",
            identity: "viewerLeft:100.64.0.1:9", blocksSomeone: false)

        XCTAssertFalse(box.value?.payload.contains("scenario=") == true)
    }

    // MARK: - Withdraw

    func testWithdrawTargetsTheTagAndGroupThatWerePosted() {
        let withdrawn = Box<(String?, String)?>(nil)
        let notifier = WindowsNotifier(testingWith: true)
        notifier.deliverForTesting = { _, _, _, _ in 1 }
        notifier.withdrawnForTesting = { withdrawn.value = ($0, $1) }

        let tag = notifier.post(summary: "s", identity: "viewerPending:100.64.0.1")
        notifier.withdraw(tag ?? "")

        XCTAssertEqual(withdrawn.value?.0, tag)
        XCTAssertEqual(withdrawn.value?.1, WindowsToastPayload.group)
    }

    /// Teardown clears the group rather than each tag: stopping a share expels
    /// every viewer at once, and a prompt left behind is one somebody can still
    /// press.
    func testWithdrawAllClearsTheGroup() {
        let withdrawn = Box<(String?, String)?>(nil)
        let notifier = WindowsNotifier(testingWith: true)
        notifier.withdrawnForTesting = { withdrawn.value = ($0, $1) }

        notifier.withdrawAll()

        XCTAssertNil(withdrawn.value?.0)
        XCTAssertEqual(withdrawn.value?.1, WindowsToastPayload.group)
    }

    // MARK: - Activation

    /// The half that does not come through this class at all: AppLifecycle
    /// hands the host a string, and this is where it turns back into an answer.
    func testDecodesItsOwnActivationArguments() {
        let arguments = WindowsToastPayload.arguments(
            action: "approve", identity: "viewerPending:100.64.0.1")
        let decoded = WindowsNotifier.decodeAction(fromActivationArguments: arguments)

        XCTAssertEqual(decoded?.action, "approve")
        XCTAssertEqual(decoded?.identity, "viewerPending:100.64.0.1")
    }

    func testForeignActivationIsRefused() {
        XCTAssertNil(WindowsNotifier.decodeAction(fromActivationArguments: "-ToastActivated"))
        XCTAssertNil(WindowsNotifier.decodeAction(fromActivationArguments: ""))
    }
}
