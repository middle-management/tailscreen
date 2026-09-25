// The two things `SharerLinkSession` talks to, named as protocols so a test
// can put a fake behind them (every method on a live `GuestServerNode` blocks
// on a DERP handshake, so nothing was drivable before this existed).
//
// Deliberately thin: it names what the session already called, nothing more,
// so ordering logic stays in the session (where the bugs were) rather than
// hiding in an adapter a test wouldn't see. The production conformances below
// contain no decisions.

import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

/// The guest tunnel's UDP side, once bound.
public protocol GuestPacketRoute: Sendable {
    func close() async
}

/// The guest tunnel's TCP control side, once bound and adopted.
public protocol GuestControlRoute: Sendable {
    func stop() async
}

/// A guest node: the ephemeral WireGuard endpoint a share link is.
///
/// Every method is `async` because the live one blocks on the network, and a
/// test needs to hold those suspension points open to exercise the actor's
/// ordering races.
public protocol GuestLinkNode: Sendable {
    /// Connects to the relay — seconds long.
    func startNode() async throws
    func openPacketRoute(port: UInt16) async throws -> any GuestPacketRoute
    /// Throws on a host that cannot carry the control channel; the session
    /// treats that as fail-soft (video and voice still flow).
    func openControlRoute(port: UInt16) async throws -> any GuestControlRoute
    func mintToken() async throws -> String
    func peerList() async throws -> [GuestPeer]
    func evictPeer(key: String) async throws
    func closeNode() async
}

/// The share server, as the link session uses it: attach the guest sockets,
/// detach them, start a share that has no other transport, stop.
public protocol GuestLinkServer: AnyObject, Sendable {
    func attachGuestPacket(_ route: any GuestPacketRoute) -> Bool
    func attachGuestControl(_ route: any GuestControlRoute) -> Bool
    func detachGuestPacket() async
    func startGuestOnlyShare(
        filterData: Data?,
        quality: QualitySettings,
        packet: any GuestPacketRoute,
        control: (any GuestControlRoute)?
    ) async throws
    func stopServer() async
}

// MARK: - The live implementations

extension PacketListener: GuestPacketRoute {}
extension TailscreenControlListener: GuestControlRoute {}

/// `GuestServerNode` behind the protocol. One piece of translation: the live
/// node hands back a bound `Listener`, and the framed-channel object that
/// adopts it is built here.
public struct LiveGuestLinkNode: GuestLinkNode {
    private let node: GuestServerNode

    public init(relayMapURL: String?, logger: LogSink?) throws {
        node = try GuestServerNode(derpMapURL: relayMapURL, logger: logger)
    }

    public func startNode() async throws { try await node.start() }

    public func openPacketRoute(port: UInt16) async throws -> any GuestPacketRoute {
        try await node.listenPacket(port: port)
    }

    public func openControlRoute(port: UInt16) async throws -> any GuestControlRoute {
        let bound = try await node.listen(port: port)
        let control = TailscreenControlListener(port: port)
        control.start(adopting: bound)
        return control
    }

    public func mintToken() async throws -> String { try await node.token() }
    public func peerList() async throws -> [GuestPeer] { try await node.peers() }
    public func evictPeer(key: String) async throws { try await node.removePeer(key: key) }
    public func closeNode() async { await node.close() }
}

/// The shipping server behind the protocol. Casts are safe by construction
/// (routes here came from `LiveGuestLinkNode`; a fake node's routes only meet
/// a fake server); a mismatch answers `false`, handled as a refused attach.
extension TailscaleScreenShareServer: GuestLinkServer {
    public func attachGuestPacket(_ route: any GuestPacketRoute) -> Bool {
        guard let listener = route as? PacketListener else { return false }
        return attachGuestPacketListener(listener)
    }

    public func attachGuestControl(_ route: any GuestControlRoute) -> Bool {
        guard let listener = route as? TailscreenControlListener else { return false }
        return attachGuestControlListener(listener)
    }

    public func detachGuestPacket() async {
        await detachGuestPacketListener()
    }

    public func startGuestOnlyShare(
        filterData: Data?,
        quality: QualitySettings,
        packet: any GuestPacketRoute,
        control: (any GuestControlRoute)?
    ) async throws {
        guard let listener = packet as? PacketListener else {
            throw SharerLinkError.attachRefused
        }
        try await startGuestOnly(
            filterData: filterData,
            quality: quality,
            guestPacketListener: listener,
            guestControlListener: control as? TailscreenControlListener)
    }

    public func stopServer() async { await stop() }
}
