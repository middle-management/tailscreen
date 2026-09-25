import Foundation
import TailscaleKit
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// A place a call can be held open, turning an actor's suspension point
/// into something a test can stand on: `hold()` makes the next call park,
/// `waitUntilParked()` lets the test proceed once it has, `release()` lets
/// it run on.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var parkedCount = 0

    /// Synchronous on purpose: an `await hold()` could only be issued after
    /// the call it means to catch has already started — a race the test
    /// loses silently. Armed from the node factory instead, before the
    /// session has anything to run.
    func hold() { lock.withLock { holding = true } }

    /// Registration comes BEFORE the announcement, under one lock
    /// acquisition, or it's a lost wakeup: `parkedCount` rises,
    /// `waitUntilParked` returns and calls `release()`, which drains a
    /// `parked` array this call hasn't appended to yet — nobody left to
    /// resume the continuation, and the test hangs rather than failing.
    /// Both resumes happen outside the lock so a continuation can't run a
    /// waiting task straight back into it.
    func passOrPark() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var waiting: [CheckedContinuation<Void, Never>] = []
            var passStraightThrough = false
            lock.withLock {
                guard holding else {
                    passStraightThrough = true
                    return
                }
                parkedCount += 1
                waiting = waiters
                waiters = []
                parked.append(continuation)
            }
            for waiter in waiting { waiter.resume() }
            if passStraightThrough { continuation.resume() }
        }
    }

    /// The check and the registration happen under ONE lock acquisition —
    /// releasing and re-taking it to append would leave a gap in which
    /// `passOrPark` arrives, snapshots an empty `waiters`, and parks, never
    /// resuming the waiter registered a moment later.
    func waitUntilParked() async {
        await withCheckedContinuation { continuation in
            let alreadyParked: Bool = lock.withLock {
                if parkedCount > 0 { return true }
                waiters.append(continuation)
                return false
            }
            // Resumed outside the lock — could run straight back into `passOrPark`.
            if alreadyParked { continuation.resume() }
        }
    }

    func release() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            let p = parked
            parked = []
            return p
        }
        for continuation in toResume { continuation.resume() }
    }
}

/// Records what happened, in order, across every fake in one test.
actor Journal {
    private(set) var entries: [String] = []
    func note(_ entry: String) { entries.append(entry) }
    func contains(_ entry: String) -> Bool { entries.contains(entry) }
    func count(of entry: String) -> Int { entries.filter { $0 == entry }.count }
    func indexOf(_ entry: String) -> Int? { entries.firstIndex(of: entry) }
}

struct FakePacketRoute: GuestPacketRoute {
    let id: String
    let journal: Journal
    func close() async { await journal.note("packet.close(\(id))") }
}

struct FakeControlRoute: GuestControlRoute {
    let id: String
    let journal: Journal
    func stop() async { await journal.note("control.stop(\(id))") }
}

/// A guest node that never touches a network. Every call notes itself and
/// passes through its gate, so a test can hold the bootstrap anywhere the
/// live one blocks.
final class FakeGuestNode: GuestLinkNode, @unchecked Sendable {
    let id: String
    let journal: Journal
    let startGate = Gate()
    let tokenGate = Gate()
    let closeGate = Gate()
    var controlFails = false
    var startFails = false
    private(set) var peers: [GuestPeer] = []
    private(set) var evicted: [String] = []

    init(id: String, journal: Journal) {
        self.id = id
        self.journal = journal
    }

    func setPeers(_ peers: [GuestPeer]) { self.peers = peers }

    func startNode() async throws {
        await journal.note("node.start(\(id))")
        await startGate.passOrPark()
        if startFails { throw SharerLinkError.attachRefused }
    }

    func openPacketRoute(port: UInt16) async throws -> any GuestPacketRoute {
        await journal.note("node.packet(\(id))")
        return FakePacketRoute(id: id, journal: journal)
    }

    func openControlRoute(port: UInt16) async throws -> any GuestControlRoute {
        await journal.note("node.control(\(id))")
        if controlFails { throw SharerLinkError.attachRefused }
        return FakeControlRoute(id: id, journal: journal)
    }

    func mintToken() async throws -> String {
        await journal.note("node.token(\(id))")
        await tokenGate.passOrPark()
        return "tc-\(id)"
    }

    func peerList() async throws -> [GuestPeer] { peers }

    func evictPeer(key: String) async throws {
        evicted.append(key)
        await journal.note("node.evict(\(key))")
    }

    func closeNode() async {
        await journal.note("node.close(\(id))")
        await closeGate.passOrPark()
    }
}

/// A share server that records the guest handshake and nothing else.
final class FakeLinkServer: GuestLinkServer, @unchecked Sendable {
    let id: String
    let journal: Journal
    private let lock = NSLock()
    private var _packetAttached: (any GuestPacketRoute)?
    private var _refuseAttach = false
    private var _refuseControlAttach = false
    private var _guestOnlyThrows: Error?
    private var _stopped = false

    init(id: String = "srv", journal: Journal) {
        self.id = id
        self.journal = journal
    }

    var packetAttached: Bool { lock.withLock { _packetAttached != nil } }
    var stopped: Bool { lock.withLock { _stopped } }
    func refuseAttach() { lock.withLock { _refuseAttach = true } }
    /// Refuse the control channel specifically — something already holds it.
    func refuseControlAttach() { lock.withLock { _refuseControlAttach = true } }
    /// Throw from `startGuestOnlyShare` (partially live server, capture fails).
    func failGuestOnly(with error: Error) { lock.withLock { _guestOnlyThrows = error } }

    func attachGuestPacket(_ route: any GuestPacketRoute) -> Bool {
        lock.withLock {
            guard !_refuseAttach, _packetAttached == nil else { return false }
            _packetAttached = route
            return true
        }
    }

    func attachGuestControl(_ route: any GuestControlRoute) -> Bool {
        lock.withLock { !_refuseControlAttach }
    }

    func detachGuestPacket() async {
        await journal.note("server.detach(\(id))")
        lock.withLock { _packetAttached = nil }
    }

    func startGuestOnlyShare(
        filterData: Data?,
        quality: QualitySettings,
        packet: any GuestPacketRoute,
        control: (any GuestControlRoute)?
    ) async throws {
        await journal.note("server.startGuestOnly(\(id))")
        if let error = lock.withLock({ _guestOnlyThrows }) { throw error }
        lock.withLock { _packetAttached = packet }
    }

    func stopServer() async {
        await journal.note("server.stop(\(id))")
        lock.withLock { _stopped = true }
    }
}
