import Foundation
import TailscaleKit
import TailscreenProtocol
import XCTest

@testable import TailscreenTransport

/// `TailscaleIPNWatcher`'s reconnect loop, through the `startWatching(subscriber:)`
/// seam — no tsnet node, no LocalAPI. `@testable` because the seam and the
/// tunable initializer are internal; the app only ever sees `startWatching(node:)`.
///
/// The bug this pins was a silent one: the watch-ipn-bus request timed out
/// after a minute of tailnet quiet, the watcher logged the error — and then
/// nothing, because `isWatching` stayed true and every owner guards on the
/// watcher already existing.
final class IPNWatcherReconnectTests: XCTestCase {

    // MARK: Fakes

    final class FakeSubscription: IPNBusSubscription {
        let cancelled = Guarded(false)
        func cancel() { cancelled.withLock { $0 = true } }
        var isCancelled: Bool { cancelled.withLock { $0 } }
    }

    /// Records every consumer the watcher subscribes with, and its handle.
    final class FakeBus: @unchecked Sendable {
        struct Attempt {
            let consumer: IPNMessageConsumer
            let handle: FakeSubscription
        }
        private let attempts = Guarded<[Attempt]>([])
        private let failures: Guarded<[Error]>

        init(failing failures: [Error] = []) {
            self.failures = Guarded(failures)
        }

        var subscriber: TailscaleIPNWatcher.Subscriber {
            { [self] consumer in
                if let error = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    throw error
                }
                let handle = FakeSubscription()
                attempts.withLock { $0.append(Attempt(consumer: consumer, handle: handle)) }
                return handle
            }
        }

        var count: Int { attempts.withLock { $0.count } }
        func attempt(_ index: Int) -> Attempt { attempts.withLock { $0[index] } }
        var last: Attempt { attempts.withLock { $0[$0.count - 1] } }
    }

    struct StreamDied: Error {}

    @MainActor
    private func makeWatcher(
        delays: [TimeInterval] = [0.01, 0.02], watchdog: Double = 15
    ) -> TailscaleIPNWatcher {
        TailscaleIPNWatcher(reconnectDelays: delays, reconnectWatchdogSeconds: watchdog)
    }

    @MainActor
    private func eventually(
        _ timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    /// For "nothing happens" legs, where a plain assert would pass before
    /// the thing it denies had a chance to happen.
    @MainActor
    private func consistently(
        _ duration: TimeInterval = 0.1, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if !condition() {
                XCTFail("condition violated", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func notify(json: String) throws -> Ipn.Notify {
        try JSONDecoder().decode(Ipn.Notify.self, from: Data(json.utf8))
    }

    // MARK: Cases

    @MainActor
    func testStreamErrorTearsDownAndResubscribes() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: bus.subscriber)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(bus.count, 1)
        let first = bus.attempt(0)

        await first.consumer.error(StreamDied())

        await eventually { bus.count == 2 }
        XCTAssertTrue(first.handle.isCancelled, "the dead subscription is released, not kept")
        await eventually { watcher.isWatching }
        XCTAssertFalse(bus.last.handle.isCancelled)
        XCTAssertTrue(bus.last.consumer !== first.consumer, "a reconnect gets its own consumer")
    }

    @MainActor
    func testIsWatchingIsOffBetweenFailureAndReconnect() async throws {
        let release = Guarded<CheckedContinuation<Void, Never>?>(nil)
        let parkedAttempts = Guarded(0)
        let bus = FakeBus()
        let inner = bus.subscriber
        let subscriber: TailscaleIPNWatcher.Subscriber = { consumer in
            let attempt = parkedAttempts.withLock {
                $0 += 1
                return $0
            }
            if attempt == 2 {
                await withCheckedContinuation { cont in
                    release.withLock { $0 = cont }
                }
            }
            return try await inner(consumer)
        }
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: subscriber)

        await bus.attempt(0).consumer.error(StreamDied())

        await eventually { release.withLock { $0 != nil } }
        XCTAssertFalse(watcher.isWatching, "off while the reconnect is still opening")
        XCTAssertEqual(bus.count, 1)

        release.withLock {
            $0?.resume()
            $0 = nil
        }
        await eventually { watcher.isWatching && bus.count == 2 }
    }

    @MainActor
    func testBrowseToURLStaysWiredAcrossReconnects() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        var opened: [URL] = []
        watcher.onBrowseToURL = { opened.append($0) }
        try await watcher.startWatching(subscriber: bus.subscriber)

        await bus.attempt(0).consumer.error(StreamDied())
        await eventually { bus.count == 2 && watcher.isWatching }

        await bus.attempt(1).consumer.notify(
            try notify(json: #"{"BrowseToURL":"https://login.tailscale.com/a/abc"}"#))

        await eventually { opened.count == 1 }
        XCTAssertEqual(opened.first?.absoluteString, "https://login.tailscale.com/a/abc")
    }

    @MainActor
    func testPeersRefillFromTheReconnectedStream() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: bus.subscriber)
        await bus.attempt(0).consumer.error(StreamDied())
        await eventually { bus.count == 2 && watcher.isWatching }

        await bus.attempt(1).consumer.notify(try notify(json: Self.netmapNotifyJSON))

        await eventually { watcher.peers.count == 1 }
        let peer = try XCTUnwrap(watcher.peers["7"])
        XCTAssertEqual(peer.hostname, "studio")
        XCTAssertEqual(
            peer.tailscaleIPs, ["100.64.0.7", "fd7a:115c:a1e0::7"], "CIDR suffixes stripped, both families kept")
        XCTAssertTrue(peer.online)
    }

    @MainActor
    func testStragglerErrorFromAReplacedSubscriptionIsIgnored() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: bus.subscriber)
        let first = bus.attempt(0)
        await first.consumer.error(StreamDied())
        await eventually { bus.count == 2 && watcher.isWatching }
        let second = bus.attempt(1)

        await first.consumer.error(StreamDied())

        await consistently { bus.count == 2 && watcher.isWatching && !second.handle.isCancelled }
    }

    @MainActor
    func testStragglerNotifyFromAReplacedSubscriptionIsIgnored() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        var opened = 0
        watcher.onBrowseToURL = { _ in opened += 1 }
        try await watcher.startWatching(subscriber: bus.subscriber)
        let first = bus.attempt(0)
        await first.consumer.error(StreamDied())
        await eventually { bus.count == 2 && watcher.isWatching }

        await first.consumer.notify(
            try notify(json: #"{"BrowseToURL":"https://login.tailscale.com/a/stale"}"#))

        await consistently { opened == 0 }
    }

    @MainActor
    func testStopDuringBackoffCancelsTheReconnect() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher(delays: [0.05])
        try await watcher.startWatching(subscriber: bus.subscriber)
        await bus.attempt(0).consumer.error(StreamDied())
        await eventually { !watcher.isWatching }

        watcher.stopWatching()

        await consistently(0.15) { bus.count == 1 && !watcher.isWatching }
    }

    @MainActor
    func testStopWhileAReconnectIsOpeningCancelsWhatItOpened() async throws {
        let release = Guarded<CheckedContinuation<Void, Never>?>(nil)
        let attemptsSeen = Guarded(0)
        let bus = FakeBus()
        let inner = bus.subscriber
        let subscriber: TailscaleIPNWatcher.Subscriber = { consumer in
            let attempt = attemptsSeen.withLock {
                $0 += 1
                return $0
            }
            if attempt == 2 {
                await withCheckedContinuation { cont in release.withLock { $0 = cont } }
            }
            return try await inner(consumer)
        }
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: subscriber)
        await bus.attempt(0).consumer.error(StreamDied())
        await eventually { release.withLock { $0 != nil } }

        watcher.stopWatching()
        release.withLock {
            $0?.resume()
            $0 = nil
        }

        await eventually { bus.count == 2 }
        await eventually { bus.attempt(1).handle.isCancelled }
        XCTAssertFalse(watcher.isWatching)
    }

    @MainActor
    func testFailedReconnectRetries() async throws {
        let bus = FakeBus()
        let inner = bus.subscriber
        let calls = Guarded(0)
        let subscriber: TailscaleIPNWatcher.Subscriber = { consumer in
            let n = calls.withLock {
                $0 += 1
                return $0
            }
            if n == 2 { throw StreamDied() }
            return try await inner(consumer)
        }
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: subscriber)
        await bus.attempt(0).consumer.error(StreamDied())

        await eventually { bus.count == 2 && watcher.isWatching }
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    @MainActor
    func testFirstStartFailingDisarmsSoTheNextStartIsAFreshOne() async throws {
        let bus = FakeBus(failing: [StreamDied()])
        let watcher = makeWatcher()

        do {
            try await watcher.startWatching(subscriber: bus.subscriber)
            XCTFail("expected the subscriber's error to propagate")
        } catch is StreamDied {}
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(bus.count, 0)

        // Not half-armed: a second start actually subscribes.
        try await watcher.startWatching(subscriber: bus.subscriber)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(bus.count, 1)
        await consistently { bus.count == 1 }
    }

    @MainActor
    func testStartIsIdempotentWhileArmed() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: bus.subscriber)
        try await watcher.startWatching(subscriber: bus.subscriber)
        XCTAssertEqual(bus.count, 1)

        await bus.attempt(0).consumer.error(StreamDied())
        try await watcher.startWatching(subscriber: bus.subscriber)
        await eventually { watcher.isWatching }
        await consistently { bus.count == 2 }
    }

    /// The processor starts inside the subscribe call, a hop before the
    /// watcher adopts the handle, so the first message can land there — and
    /// with `.initialState` the first message carries the login URL.
    @MainActor
    func testNotifyDeliveredWhileStillOpeningIsHonoured() async throws {
        let release = Guarded<CheckedContinuation<Void, Never>?>(nil)
        let opening = Guarded<IPNMessageConsumer?>(nil)
        let bus = FakeBus()
        let inner = bus.subscriber
        let subscriber: TailscaleIPNWatcher.Subscriber = { consumer in
            opening.withLock { $0 = consumer }
            await withCheckedContinuation { cont in release.withLock { $0 = cont } }
            return try await inner(consumer)
        }
        let watcher = makeWatcher()
        var opened: [URL] = []
        watcher.onBrowseToURL = { opened.append($0) }

        let start = Task { try await watcher.startWatching(subscriber: subscriber) }
        await eventually { release.withLock { $0 != nil } }
        let consumer = try XCTUnwrap(opening.withLock { $0 })
        await consumer.notify(try notify(json: #"{"BrowseToURL":"https://login.tailscale.com/a/early"}"#))
        await eventually { opened.count == 1 }

        release.withLock {
            $0?.resume()
            $0 = nil
        }
        try await start.value
        XCTAssertTrue(watcher.isWatching)
    }

    /// A stream that dies in that same window is not lost as a straggler.
    @MainActor
    func testErrorDeliveredWhileStillOpeningStillReconnects() async throws {
        let release = Guarded<CheckedContinuation<Void, Never>?>(nil)
        let opening = Guarded<IPNMessageConsumer?>(nil)
        let attemptsSeen = Guarded(0)
        let bus = FakeBus()
        let inner = bus.subscriber
        let subscriber: TailscaleIPNWatcher.Subscriber = { consumer in
            if attemptsSeen.withLock({
                $0 += 1
                return $0
            }) == 1 {
                opening.withLock { $0 = consumer }
                await withCheckedContinuation { cont in release.withLock { $0 = cont } }
            }
            return try await inner(consumer)
        }
        let watcher = makeWatcher()

        let start = Task { try await watcher.startWatching(subscriber: subscriber) }
        await eventually { release.withLock { $0 != nil } }
        let consumer = try XCTUnwrap(opening.withLock { $0 })
        await consumer.error(StreamDied())
        release.withLock {
            $0?.resume()
            $0 = nil
        }
        try await start.value

        await eventually { bus.count == 2 && watcher.isWatching }
        XCTAssertTrue(bus.attempt(0).handle.isCancelled, "the stream that died while opening is released")
    }

    /// Two attempts can be opening at once. If the older one's stream dies
    /// before it returns, and it returns first, it must not be installed as
    /// the live subscription — or the watcher sits on a dead stream
    /// reporting `isWatching == true` with no reconnect scheduled.
    @MainActor
    func testTimedOutAttemptThatDiedWhileParkedIsNotAdoptedLive() async throws {
        let parked = Guarded<[(IPNMessageConsumer, CheckedContinuation<Void, Never>)]>([])
        let attemptsSeen = Guarded(0)
        let bus = FakeBus()
        let inner = bus.subscriber
        let subscriber: TailscaleIPNWatcher.Subscriber = { consumer in
            if attemptsSeen.withLock({
                $0 += 1
                return $0
            }) > 1 {
                await withCheckedContinuation { cont in
                    parked.withLock { $0.append((consumer, cont)) }
                }
            }
            return try await inner(consumer)
        }
        let watcher = makeWatcher(delays: [0.01], watchdog: 0.05)
        try await watcher.startWatching(subscriber: subscriber)
        await bus.attempt(0).consumer.error(StreamDied())

        await eventually { parked.withLock { $0.count } == 2 }
        let (older, releaseOlder) = parked.withLock { $0[0] }
        let (_, releaseNewer) = parked.withLock { $0[1] }

        await older.error(StreamDied())
        releaseOlder.resume()

        await eventually { bus.count == 2 }
        await eventually { bus.attempt(1).handle.isCancelled }
        XCTAssertFalse(watcher.isWatching, "a stream that died while opening is never live")

        releaseNewer.resume()
        await eventually { watcher.isWatching }
        XCTAssertFalse(bus.last.handle.isCancelled)
    }

    @MainActor
    func testStopCancelsTheLiveSubscription() async throws {
        let bus = FakeBus()
        let watcher = makeWatcher()
        try await watcher.startWatching(subscriber: bus.subscriber)

        watcher.stopWatching()

        XCTAssertTrue(bus.attempt(0).handle.isCancelled)
        XCTAssertFalse(watcher.isWatching)
        await bus.attempt(0).consumer.error(StreamDied())
        await consistently { bus.count == 1 }
    }

    // MARK: Fixtures

    static let netmapNotifyJSON = #"""
        {
          "Version": "1.102.3",
          "NetMap": {
            "SelfNode": {
              "ID": 1, "StableID": "nSELF", "Name": "me.tail.ts.net.", "User": 100,
              "Key": "nodekey:00", "Addresses": ["100.64.0.1/32"],
              "Hostinfo": {"OS": "macOS", "Hostname": "me"},
              "ComputedName": "me", "ComputedNameWithHost": "me"
            },
            "NodeKey": "nodekey:00",
            "Peers": [
              {
                "ID": 7, "StableID": "nPEER", "Name": "studio.tail.ts.net.", "User": 100,
                "Key": "nodekey:07", "Addresses": ["100.64.0.7/32", "fd7a:115c:a1e0::7/128"],
                "Hostinfo": {"OS": "linux", "Hostname": "studio"},
                "Online": true, "Tags": ["tag:studio"],
                "ComputedName": "studio", "ComputedNameWithHost": "studio"
              }
            ],
            "DNS": {},
            "Domain": "example.com",
            "UserProfiles": {"100": {"ID": 100, "LoginName": "a@example.com", "DisplayName": "A"}}
          }
        }
        """#
}
