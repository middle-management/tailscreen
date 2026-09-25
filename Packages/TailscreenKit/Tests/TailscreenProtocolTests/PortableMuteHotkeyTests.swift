import Foundation
import XCTest

@testable import TailscreenProtocol

/// `PortableMuteHotkey` — the controller both swift-cross-ui apps wrap their
/// platform hotkey shim in. Driven a tick at a time through a fake binding,
/// so every rule is asserted without an X server, `RegisterHotKey`, or a
/// 50ms sleep.
final class PortableMuteHotkeyTests: XCTestCase {

    private final class FakeHotkey: GlobalHotkeyHolding {
        var pending = 0
        private(set) var releaseCount = 0
        func drain() -> Int {
            let value = pending
            pending = 0
            return value
        }
        func release() { releaseCount += 1 }
    }

    private final class FakeBinding: GlobalHotkeyBinding {
        var answer: Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability>
        private(set) var holdCount = 0
        private(set) var live: FakeHotkey?

        init(answer: Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability>) {
            self.answer = answer
        }

        static func granting() -> FakeBinding {
            let hotkey = FakeHotkey()
            let binding = FakeBinding(answer: .success(hotkey))
            binding.live = hotkey
            return binding
        }

        func hold(
            _ chord: ShortcutChord
        ) -> Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability> {
            holdCount += 1
            return answer
        }
    }

    @MainActor
    private final class Host {
        var sharerMic = false
        var viewerMic = false
        var sharerToggles = 0
        var viewerToggles = 0
        var notes: [String] = []
    }

    @MainActor
    private func makeController(
        binding: FakeBinding, host: Host
    ) throws -> PortableMuteHotkey {
        // `notes` is appended from a `@Sendable` closure driven only on the
        // main actor; `assumeIsolated` is the honest spelling of that.
        let controller = PortableMuteHotkey(
            binding: binding,
            sharerMicAvailable: { host.sharerMic },
            viewerMicAvailable: { host.viewerMic },
            toggleSharerMic: { host.sharerToggles += 1 },
            toggleViewerMic: { host.viewerToggles += 1 },
            note: { message in
                MainActor.assumeIsolated { host.notes.append(message) }
            })
        return try XCTUnwrap(controller, "the catalog must carry a global toggleMicrophone entry")
    }

    // MARK: Holding the chord

    /// A global grab is exclusive — it takes it from every other app on the
    /// machine — so holding it with nothing to mute has no handler.
    @MainActor
    func testTheChordIsNotHeldWhileThereIsNothingToMute() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        controller.tick()
        XCTAssertEqual(binding.holdCount, 0)
        XCTAssertNil(controller.target)
        XCTAssertNil(controller.chordHint, "nothing is held, so nothing may be advertised")
    }

    @MainActor
    func testAMicrophoneAppearingTakesTheChordAndOneGoingAwayReleasesIt() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        host.viewerMic = true
        controller.tick()
        XCTAssertEqual(binding.holdCount, 1)
        XCTAssertEqual(controller.target, .viewer)
        XCTAssertNotNil(controller.chordHint)

        host.viewerMic = false
        controller.tick()
        XCTAssertEqual(binding.live?.releaseCount, 1)
        XCTAssertNil(controller.target)
    }

    /// Re-taking the chord is expensive on Windows (destroys and recreates
    /// the shim's pump thread), so the hold decision is acted on only when
    /// it changes.
    @MainActor
    func testTheChordIsTakenOnceAndNotReTakenEveryTick() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        host.sharerMic = true
        for _ in 0..<5 { controller.tick() }
        XCTAssertEqual(binding.holdCount, 1)
        XCTAssertEqual(binding.live?.releaseCount, 0)
    }

    // MARK: Routing a press

    /// A double press inside one tick is two toggles, which for a mute
    /// means it lands back where it started.
    @MainActor
    func testAPressFlipsTheTargetedMicrophoneOncePerActivation() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        host.viewerMic = true
        controller.tick()
        binding.live?.pending = 2
        controller.tick()
        XCTAssertEqual(host.viewerToggles, 2)
        XCTAssertEqual(host.sharerToggles, 0)
    }

    /// The sharer wins when both are live — during a share the window
    /// carrying the button is behind whatever is being shown.
    @MainActor
    func testStartingAShareRetargetsThePressAndSaysSo() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        host.viewerMic = true
        controller.tick()
        let afterFirstTarget = host.notes.count

        host.sharerMic = true
        controller.tick()
        XCTAssertEqual(controller.target, .sharer)
        binding.live?.pending = 1
        controller.tick()
        XCTAssertEqual(host.sharerToggles, 1)
        XCTAssertEqual(host.viewerToggles, 0)
        XCTAssertGreaterThan(
            host.notes.count, afterFirstTarget,
            "a silent retarget is a user finding out by pressing it")
    }

    @MainActor
    func testTheTargetIsAnnouncedOnChangeOnly() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        host.viewerMic = true
        controller.tick()
        let settled = host.notes.count
        for _ in 0..<5 { controller.tick() }
        XCTAssertEqual(host.notes.count, settled)
    }

    // MARK: Failure

    /// A mute hotkey that never registered looks exactly like one that works
    /// until pressed — the reason is surfaced, and `chordHint` withholds the
    /// chord so no UI teaches it.
    @MainActor
    func testAnUnavailableChordIsReportedAndNeverAdvertised() async throws {
        let binding = FakeBinding(answer: .failure(.alreadyOwned))
        let host = Host()
        let controller = try makeController(binding: binding, host: host)
        var mirrored: [GlobalHotkeyUnavailability?] = []
        controller.onUnavailabilityChange = { mirrored.append($0) }

        host.sharerMic = true
        controller.tick()
        XCTAssertEqual(controller.unavailability, .alreadyOwned)
        XCTAssertNil(controller.chordHint)
        XCTAssertEqual(mirrored, [.alreadyOwned])
    }

    @MainActor
    func testAFailureIsLoggedAndMirroredOnceNotPerTick() async throws {
        let binding = FakeBinding(answer: .failure(.noDisplay))
        let host = Host()
        let controller = try makeController(binding: binding, host: host)
        var mirrored = 0
        controller.onUnavailabilityChange = { _ in mirrored += 1 }

        host.sharerMic = true
        for _ in 0..<10 { controller.tick() }
        XCTAssertEqual(host.notes.count, 1)
        XCTAssertEqual(mirrored, 1)
        // Kept trying — a chord another app holds can be given back.
        XCTAssertEqual(binding.holdCount, 10)
    }

    @MainActor
    func testRecoveringFromAFailureClearsTheReasonAndReAdvertises() async throws {
        let binding = FakeBinding(answer: .failure(.alreadyOwned))
        let host = Host()
        let controller = try makeController(binding: binding, host: host)
        var mirrored: [GlobalHotkeyUnavailability?] = []
        controller.onUnavailabilityChange = { mirrored.append($0) }

        host.sharerMic = true
        controller.tick()
        let hotkey = FakeHotkey()
        binding.answer = .success(hotkey)
        controller.tick()

        XCTAssertNil(controller.unavailability)
        XCTAssertEqual(controller.chordHint, controller.chordDisplay)
        XCTAssertEqual(mirrored, [.alreadyOwned, nil])
    }

    @MainActor
    func testActivationsAreNotRoutedOnceTheTargetIsGone() async throws {
        let binding = FakeBinding.granting()
        let host = Host()
        let controller = try makeController(binding: binding, host: host)

        host.viewerMic = true
        controller.tick()
        binding.live?.pending = 3
        host.viewerMic = false
        controller.tick()

        XCTAssertEqual(host.viewerToggles, 0)
        XCTAssertEqual(host.sharerToggles, 0)
    }
}
