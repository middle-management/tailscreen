// The two seams `SharerLinkSession` reaches the outside world through, so
// its ordering rules can be driven by a test instead of by a relay.
//
// Why they exist at all: every method on the session used to take a real
// `GuestServerNode` (whose `start()` blocks on a DERP handshake over the
// network) and a real `TailscaleScreenShareServer`. That made the file
// untestable, and the file is almost entirely ordering around `await` —
// two review rounds on PR #304 found eight concurrency bugs in it and its
// callers, and not one was catchable by the suites we had. The extracted-
// decision pattern the rest of this tier uses does not reach these: there
// is no pure answer to extract, only *when* a claim is taken, *when* state
// is blanked, and *what* is closed on the way out.
//
// The seam is deliberately two protocols rather than one, because the
// listener is the thing that travels: the node vends it and the server
// adopts it. Abstracting only the node would leave the session handing a
// real socket to a real server, which is the half that cannot run headless.
//
// Everything here is a narrow view of a type that already exists — no
// production behaviour lives in this file. `RealGuestNode` is the only
// implementation the apps ever construct, and it is what
// `SharerLinkSession`'s default factory returns.

import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

/// The guest tunnel's UDP socket, as the link session sees it.
///
/// The session never reads or writes it — it hands it to the server and,
/// on the one path where nothing adopts it, closes it. So `close()` is the
/// entire surface, and a test double is three lines.
public protocol GuestPacketListening: Sendable {
    func close() async
}

/// The guest tunnel's framed TCP control channel (annotations and remote
/// control for guests), as the link session sees it.
public protocol GuestControlChanneling: Sendable {
    func stop() async
}

/// The guest node's lifecycle, as the link session drives it.
///
/// One deliberate difference from `GuestServerNode`: `listenControl` stands
/// where the node's `listen(port:)` does. The session's only use of a bound
/// TCP listener is to wrap it in a started `TailscreenControlListener`, and
/// that wrapping needs the concrete `Listener` — so the pair travels as one
/// step and the seam hands back the thing the session actually holds. The
/// fail-soft rule is unchanged: a throw from here costs the link its
/// annotations and remote control, never its video and voice.
public protocol GuestNodeProviding: Sendable {
    /// Connects to the relay and begins accepting clients. Blocks for the
    /// bootstrap — this is the await a stop or a second start lands inside.
    func start() async throws
    func listenPacket(port: UInt16) async throws -> any GuestPacketListening
    func listenControl(port: UInt16) async throws -> any GuestControlChanneling
    func token() async throws -> String
    func peers() async throws -> [GuestPeer]
    func removePeer(key: String) async throws
    func close() async
}

/// The half of `TailscaleScreenShareServer` the link session drives.
///
/// Named to match the server's own methods so the call sites read the same
/// after the seam as before it; `detachGuestPacketListener()` and `stop()`
/// are satisfied by the server directly, with no adapter to drift.
public protocol GuestLinkServing: AnyObject, Sendable {
    func attachGuestPacketListener(_ listener: any GuestPacketListening) -> Bool
    func attachGuestControlListener(_ channel: any GuestControlChanneling) -> Bool
    func detachGuestPacketListener() async
    func startGuestOnly(
        filterData: Data?,
        quality: QualitySettings,
        guestPacketListener: any GuestPacketListening,
        guestControlListener: (any GuestControlChanneling)?
    ) async throws
    func stop() async
}

/// Builds the guest node a mint runs on. `SharerLinkSession`'s default is
/// `RealGuestNode`; a test passes its own to get a node with no network
/// under it and a suspension point wherever it needs one.
public typealias GuestNodeFactory =
    @Sendable (_ relayMapURL: String?, _ logger: (any LogSink)?) throws -> any GuestNodeProviding

// MARK: - The real implementations

extension PacketListener: GuestPacketListening {}
extension TailscreenControlListener: GuestControlChanneling {}

/// `GuestServerNode` behind the seam. A struct rather than a subclass
/// because the node is an actor and this adds no state of its own — it
/// exists to widen two return types and to fold `listen` + `start(adopting:)`
/// into the one step the session takes.
public struct RealGuestNode: GuestNodeProviding {
    private let node: GuestServerNode

    public init(derpMapURL: String? = nil, logger: (any LogSink)? = nil) throws {
        node = try GuestServerNode(derpMapURL: derpMapURL, logger: logger)
    }

    public func start() async throws { try await node.start() }

    public func listenPacket(port: UInt16) async throws -> any GuestPacketListening {
        try await node.listenPacket(port: port)
    }

    public func listenControl(port: UInt16) async throws -> any GuestControlChanneling {
        let bound = try await node.listen(port: port)
        let control = TailscreenControlListener(port: port)
        control.start(adopting: bound)
        return control
    }

    public func token() async throws -> String { try await node.token() }
    public func peers() async throws -> [GuestPeer] { try await node.peers() }
    public func removePeer(key: String) async throws { try await node.removePeer(key: key) }
    public func close() async { await node.close() }
}

/// Raised when a real server is handed a listener a real node did not vend.
/// Unreachable in the app — `RealGuestNode` is the only factory the hosts
/// install, and it vends nothing else — but the alternative is a force-cast
/// in a path whose whole point is unwinding cleanly.
public struct GuestListenerNotAdoptable: Error, Sendable {
    public let detail: String
}

/// The server's own guest surface, seen through the seam. The downcasts are
/// the honest statement of what a real server can adopt: a real socket. A
/// refusal here takes the same unwind as any other refusal — the session
/// closes what it made and leaves no token behind.
extension TailscaleScreenShareServer: GuestLinkServing {
    public func attachGuestPacketListener(_ listener: any GuestPacketListening) -> Bool {
        // Not a tsnet socket: the real server has nothing to receive on.
        guard let pl = listener as? PacketListener else { return false }
        return attachGuestPacketListener(pl)
    }

    public func attachGuestControlListener(_ channel: any GuestControlChanneling) -> Bool {
        guard let control = channel as? TailscreenControlListener else { return false }
        return attachGuestControlListener(control)
    }

    public func startGuestOnly(
        filterData: Data?,
        quality: QualitySettings,
        guestPacketListener: any GuestPacketListening,
        guestControlListener: (any GuestControlChanneling)?
    ) async throws {
        guard let pl = guestPacketListener as? PacketListener else {
            throw GuestListenerNotAdoptable(detail: "guest UDP listener is not a tsnet socket")
        }
        let control = guestControlListener as? TailscreenControlListener
        if guestControlListener != nil && control == nil {
            throw GuestListenerNotAdoptable(detail: "guest TCP channel is not a control listener")
        }
        try await startGuestOnly(
            filterData: filterData,
            quality: quality,
            guestPacketListener: pl,
            guestControlListener: control)
    }
}
