import Foundation
import TailscaleKit
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// A place a call can be held open.
///
/// The point of the whole fake: `SharerLinkSession` is an actor, so it
/// yields at every `await`, and every bug this suite exists for lived in
/// what another caller did during one of those yields. A `Gate` turns a
/// suspension point into something a test can stand on — `hold()` makes the
/// next call park, `waitUntilParked()` lets the test proceed once it has,
/// and `release()` lets it run on.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var parkedCount = 0

    /// Synchronous on purpose. An `await hold()` can only be issued after
    /// the call it means to catch has already started, which is a race the
    /// test loses silently: the bootstrap runs past the gate, nothing ever
    /// parks, and `waitUntilParked` hangs forever. Armed from the node
    /// factory instead, before the session has anything to run.
    func hold() { lock.withLock { holding = true } }

    /// Called from inside the faked operation.
    ///
    /// The "should I park" answer and the waiter list come out of the same
    /// lock acquisition, as a flag beside an ordinary array rather than an
    /// optional one — `discouraged_optional_collection` is on in this repo,
    /// and an empty list means the same thing here anyway. The resumes
    /// happen outside the lock so a continuation cannot re-enter it.
    func passOrPark() async {
        var shouldPark = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            guard holding else { return }
            shouldPark = true
            parkedCount += 1
            waiting = waiters
            waiters = []
        }
        for waiter in waiting { waiter.resume() }
        guard shouldPark else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { parked.append(continuation) }
        }
    }

    /// Block the test until something is parked here.
    ///
    /// The check and the registration happen under ONE lock acquisition, and
    /// that is the whole of it. Reading `parkedCount`, releasing, and then
    /// re-taking the lock to append leaves a gap a few instructions wide in
    /// which `passOrPark` can arrive: it increments the count, snapshots a
    /// `waiters` list that is still empty, and parks — and the waiter
    /// registered a moment later is never resumed. That is the same
    /// lost-wakeup `hold()` is synchronous to avoid, one function along, and
    /// its symptom is the same: the test hangs rather than failing.
    func waitUntilParked() async {
        await withCheckedContinuation { continuation in
            let alreadyParked: Bool = lock.withLock {
                if parkedCount > 0 { return true }
                waiters.append(continuation)
                return false
            }
            // Resumed OUTSIDE the lock — a continuation resumed while holding
            // it can run the waiting task straight back into `passOrPark`.
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

/// A guest node that never touches a network.
///
/// Every call notes itself and passes through its gate, so a test can hold
/// the bootstrap anywhere the live one blocks. `token` is per node, which is
/// what lets a test tell one attempt's link from another's.
final class FakeGuestNode: GuestLinkNode, @unchecked Sendable {
    let id: String
    let journal: Journal
    let startGate = Gate()
    let tokenGate = Gate()
    let closeGate = Gate()
    /// Set to make `openControlRoute` throw — the fail-soft leg.
    var controlFails = false
    /// Set to make `startNode` throw — a relay that never answered.
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
    /// Refuse the CONTROL channel specifically — the share is running and
    /// took the socket, but something already holds its guest control
    /// channel. The session owns stopping what the server did not adopt.
    func refuseControlAttach() { lock.withLock { _refuseControlAttach = true } }
    /// Throw from `startGuestOnlyShare` — the case where the server is
    /// already partially live when capture fails.
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
