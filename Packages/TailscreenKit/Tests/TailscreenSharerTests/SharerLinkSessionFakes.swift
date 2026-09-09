// The doubles `SharerLinkSessionTests` drives the link session with: a
// guest node with no relay under it, a server that records instead of
// sharing, and the thing that makes both worth having — a suspension point
// a test can park the session at and release on purpose.
//
// Every rule that suite pins is about what happens to state ACROSS an
// await, so a double that merely returns fast pins nothing: the bugs need
// a second caller to arrive while the first is still inside the bootstrap.
// `Gate` is how that is arranged deterministically, with no sleeping and
// no race for the window.

import Foundation
import Synchronization
import TailscaleKit
import TailscreenProtocol
import TailscreenSharer

// MARK: - The suspension point

/// A parking spot in the code under test.
///
/// `pass()` is called by a fake; it returns at once unless the gate is
/// armed, in which case it suspends until `open()`. `waitForArrival()` lets
/// the test wait until somebody is actually parked, so the "run a stop
/// while the mint is mid-bootstrap" sequence is ordered by the gate rather
/// than by hoping a `Task.yield` was enough.
actor Gate {
    private var isOpen: Bool
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivalWatchers: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0

    /// `armed: false` builds a gate nothing waits at — the default for every
    /// operation a given test is not interested in parking.
    init(armed: Bool = false) { isOpen = !armed }

    /// Called from the fake. Suspends while the gate is shut.
    func pass() async {
        if isOpen { return }
        arrived += 1
        for w in arrivalWatchers { w.resume() }
        arrivalWatchers.removeAll()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            parked.append(c)
        }
    }

    /// Releases everyone parked, and everyone who arrives later.
    func open() {
        isOpen = true
        let waiting = parked
        parked.removeAll()
        for c in waiting { c.resume() }
    }

    /// Returns once `count` callers have parked here (or already had).
    func waitForArrival(count: Int = 1) async {
        while arrived < count {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                arrivalWatchers.append(c)
            }
        }
    }
}

// MARK: - The ordered event log

/// One log both fakes append to, so a test can assert that the detach
/// happened BEFORE the node close rather than merely that both happened.
/// Appends are synchronous because the server's attach methods are.
final class EventLog: Sendable {
    private let entries = Mutex<[String]>([])

    func record(_ event: String) { entries.withLock { $0.append(event) } }
    var all: [String] { entries.withLock { $0 } }
    func count(of event: String) -> Int { all.filter { $0 == event }.count }

    /// Index of the first occurrence, or nil. `XCTAssertLessThan` over two of
    /// these is how the ordering rules are stated.
    func firstIndex(of event: String) -> Int? { all.firstIndex(of: event) }
}

// MARK: - The guest node

final class FakePacketListener: GuestPacketListening {
    let log: EventLog
    let name: String
    init(log: EventLog, name: String) {
        self.log = log
        self.name = name
    }
    func close() async { log.record("\(name).packetListener.close") }
}

final class FakeControlChannel: GuestControlChanneling {
    let log: EventLog
    let name: String
    init(log: EventLog, name: String) {
        self.log = log
        self.name = name
    }
    func stop() async { log.record("\(name).control.stop") }
}

/// A guest node with no DERP handshake under it.
///
/// `name` prefixes every event so a test running two mints can tell the
/// superseded node's close from the winner's — which is the whole question
/// in the claim-ownership rules.
final class FakeGuestNode: GuestNodeProviding {
    struct Failures: Sendable {
        var start: (any Error)?
        var listenPacket: (any Error)?
        var listenControl: (any Error)?
        var token: (any Error)?
        var removePeer: (any Error)?
    }

    let name: String
    let log: EventLog
    let mintedToken: String
    let failures: Failures
    let guestPeers: [GuestPeer]

    /// Armed gates park the session inside that call. `start` and `token`
    /// are the two that matter most: the first is where a real relay
    /// bootstrap blocks, the second is the last await before the publish.
    let startGate: Gate
    let listenPacketGate: Gate
    let tokenGate: Gate
    let closeGate: Gate

    let packetListener: FakePacketListener

    init(
        name: String,
        log: EventLog,
        mintedToken: String,
        failures: Failures = Failures(),
        guestPeers: [GuestPeer] = [],
        armStart: Bool = false,
        armListenPacket: Bool = false,
        armToken: Bool = false,
        armClose: Bool = false
    ) {
        self.name = name
        self.log = log
        self.mintedToken = mintedToken
        self.failures = failures
        self.guestPeers = guestPeers
        startGate = Gate(armed: armStart)
        listenPacketGate = Gate(armed: armListenPacket)
        tokenGate = Gate(armed: armToken)
        closeGate = Gate(armed: armClose)
        packetListener = FakePacketListener(log: log, name: name)
    }

    private let removedKeys = Mutex<[String]>([])
    var evictedKeys: [String] { removedKeys.withLock { $0 } }

    func start() async throws {
        log.record("\(name).start")
        await startGate.pass()
        if let e = failures.start { throw e }
    }

    func listenPacket(port: UInt16) async throws -> any GuestPacketListening {
        log.record("\(name).listenPacket")
        await listenPacketGate.pass()
        if let e = failures.listenPacket { throw e }
        return packetListener
    }

    func listenControl(port: UInt16) async throws -> any GuestControlChanneling {
        log.record("\(name).listenControl")
        if let e = failures.listenControl { throw e }
        return FakeControlChannel(log: log, name: name)
    }

    func token() async throws -> String {
        log.record("\(name).token")
        await tokenGate.pass()
        if let e = failures.token { throw e }
        return mintedToken
    }

    func peers() async throws -> [GuestPeer] { guestPeers }

    func removePeer(key: String) async throws {
        log.record("\(name).removePeer")
        if let e = failures.removePeer { throw e }
        removedKeys.withLock { $0.append(key) }
    }

    func close() async {
        log.record("\(name).close")
        await closeGate.pass()
    }
}

// MARK: - The server

/// A server that records the link handshake instead of running a share.
///
/// Deliberately NOT a `TailscaleScreenShareServer` in test mode: the rules
/// being pinned are about what the session does with the server's ANSWERS
/// (an attach that refuses, a `startGuestOnly` that throws), and the real
/// server has no way to be told to refuse.
final class FakeLinkServer: GuestLinkServing {
    struct State {
        var attachPacketAnswer = true
        var attachControlAnswer = true
        var startGuestOnlyError: (any Error)?
        var attachedPacket: (any GuestPacketListening)?
        var attachedControl: (any GuestControlChanneling)?
    }

    let log: EventLog
    private let state: Mutex<State>

    init(
        log: EventLog,
        attachPacketAnswer: Bool = true,
        attachControlAnswer: Bool = true,
        startGuestOnlyError: (any Error)? = nil
    ) {
        self.log = log
        var s = State()
        s.attachPacketAnswer = attachPacketAnswer
        s.attachControlAnswer = attachControlAnswer
        s.startGuestOnlyError = startGuestOnlyError
        state = Mutex(s)
    }

    var attachedPacket: (any GuestPacketListening)? { state.withLock { $0.attachedPacket } }
    var attachedControl: (any GuestControlChanneling)? { state.withLock { $0.attachedControl } }

    func attachGuestPacketListener(_ listener: any GuestPacketListening) -> Bool {
        let answer = state.withLock { s -> Bool in
            guard s.attachPacketAnswer else { return false }
            s.attachedPacket = listener
            return true
        }
        log.record(answer ? "server.attachPacket" : "server.attachPacket.refused")
        return answer
    }

    func attachGuestControlListener(_ channel: any GuestControlChanneling) -> Bool {
        let answer = state.withLock { s -> Bool in
            guard s.attachControlAnswer else { return false }
            s.attachedControl = channel
            return true
        }
        log.record(answer ? "server.attachControl" : "server.attachControl.refused")
        return answer
    }

    func detachGuestPacketListener() async {
        state.withLock {
            $0.attachedPacket = nil
            $0.attachedControl = nil
        }
        log.record("server.detach")
    }

    func startGuestOnly(
        filterData: Data?,
        quality: QualitySettings,
        guestPacketListener: any GuestPacketListening,
        guestControlListener: (any GuestControlChanneling)?
    ) async throws {
        log.record("server.startGuestOnly")
        // The real one marks itself running and installs its receive/sweep
        // loops BEFORE the capture backend can fail, which is exactly why a
        // throw from here has to stop the server too — so record the attach
        // first and throw after, the same order the real one fails in.
        state.withLock {
            $0.attachedPacket = guestPacketListener
            $0.attachedControl = guestControlListener
        }
        if let e = state.withLock({ $0.startGuestOnlyError }) { throw e }
    }

    func stop() async {
        state.withLock {
            $0.attachedPacket = nil
            $0.attachedControl = nil
        }
        log.record("server.stop")
    }
}

// MARK: - Shared fixtures

struct LinkTestError: Error, Equatable, Sendable {
    let what: String
}

/// `GuestPeer`'s memberwise init is internal to TailscaleKit, but the type
/// is `Codable` — which is how the real node builds them too, from the
/// node's JSON.
func makeGuestPeer(key: String, addr: String) throws -> GuestPeer {
    let json = #"{"key":"\#(key)","addr":"\#(addr)"}"#
    return try JSONDecoder().decode(GuestPeer.self, from: Data(json.utf8))
}
