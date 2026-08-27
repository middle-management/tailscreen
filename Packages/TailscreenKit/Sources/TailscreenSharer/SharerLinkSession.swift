// The sharer's link (share-by-token) half as one portable object: the
// guest node's lifecycle, the attach/detach handshake with the server, New
// Link rotation, and the deny→tunnel-evict mapping. Written once here so
// the GTK and WinUI share engines drive identical rules — the macOS
// AppState grew the same logic first (phase 4) and keeps its own copy for
// now; converging it is a rename-shaped follow-up, not a design question.
//
// An actor: every host calls it from async context (the guest node's DERP
// bootstrap blocks for the network), and the two engines guard themselves
// differently (@MainActor vs. lock) — an actor is the shape neither has to
// adapt to.

import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

public enum SharerLinkError: Error, Sendable {
    /// The server refused the listener — the share stopped (or already has
    /// a guest listener) while the guest node was coming up. Nothing was
    /// adopted; the session closed the socket and the node.
    case attachRefused
}

public actor SharerLinkSession {
    private var guestServer: GuestServerNode?
    /// Tunnel IP → admitted guest peer, refreshed lazily. Supplies key
    /// fingerprints and the eviction lookup (`onGuestViewerDenied` reports
    /// an IP; `removePeer` wants the node key).
    private var peersByIP: [String: GuestPeer] = [:]
    /// The live link's token — non-nil exactly while the guest node is up.
    public private(set) var token: String?
    private let logger: LogSink?

    public init(logger: LogSink? = nil) {
        self.logger = logger
    }

    /// Mint a link on a running share: guest node up, its listener attached
    /// as the server's guest socket, token returned. Blocks for the relay
    /// bootstrap. Idempotent — an already-live link returns its token.
    public func enable(
        on server: TailscaleScreenShareServer,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        if let token, guestServer != nil { return token }
        let gs = try GuestServerNode(derpMapURL: relayMapURL, logger: logger)
        try await gs.start()
        let pl = try await gs.listenPacket(port: port)
        guard server.attachGuestPacketListener(pl) else {
            // The share raced to a stop (or somehow already holds a guest
            // listener): nothing adopted the socket, so close it here and
            // leave no live token behind a share that isn't there.
            await pl.close()
            await gs.close()
            throw SharerLinkError.attachRefused
        }
        // The tunnel's TCP side: the framed control channel that gives
        // guests annotations and remote control. Fail-soft — a link whose
        // TCP bind failed still carries video and voice, which is the core
        // of a share; the loud log is the debugging trail for the dead
        // affordances that would result. (In practice a node whose UDP
        // listen just succeeded binds TCP too.) The server owns stopping
        // it: detach and share-stop both close the adopted channel.
        do {
            let tcp = try await gs.listen(port: port)
            let control = TailscreenControlListener(port: port)
            control.start(adopting: tcp)
            if !server.attachGuestControlListener(control) {
                await control.stop()
            }
        } catch {
            logger?.log(
                "Guest TCP control channel unavailable (\(error)) — link carries video/voice only")
        }
        let minted = try await gs.token()
        guestServer = gs
        token = minted
        logger?.log("Share link active")
        return minted
    }

    /// Kill the link on a still-running share: detach first (each guest
    /// gets HELLO_DENY + SERVER_BYE through the still-open guest socket),
    /// then close the node — the token is dead forever. No-op with no link.
    public func disable(on server: TailscaleScreenShareServer?) async {
        guard guestServer != nil || token != nil else { return }
        await server?.detachGuestPacketListener()
        await close()
        logger?.log("Share link stopped — token dead")
    }

    /// New Link: the old token dies the moment this starts (current guests
    /// drop with it), and a fresh node key mints a fresh token.
    public func rotate(
        on server: TailscaleScreenShareServer,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        await disable(on: server)
        return try await enable(on: server, relayMapURL: relayMapURL, port: port)
    }

    /// The share ended: the server's own stop already closed the listener
    /// and told every guest, so only the node is left to tear down.
    public func teardown() async {
        await close()
    }

    /// Map a denied guest's tunnel IP back to its node key and evict it at
    /// the tunnel — flows close now, and the key is refused for the life of
    /// this link. Wire `server.onGuestViewerDenied` at share start:
    ///
    ///     server.onGuestViewerDenied = { [link] ip in
    ///         Task { await link.evict(ip: ip) }
    ///     }
    public func evict(ip: String) async {
        guard let gs = guestServer else { return }
        await refreshPeers()
        guard let peer = peersByIP[ip] else {
            logger?.log("Guest evict: no peer for \(ip) (already gone)")
            return
        }
        do {
            try await gs.removePeer(key: peer.key)
        } catch {
            logger?.log("Guest evict failed for \(ip): \(error)")
        }
        peersByIP.removeValue(forKey: ip)
    }

    /// Refresh the tunnel-IP → peer map from the guest node.
    public func refreshPeers() async {
        guard let gs = guestServer else {
            peersByIP = [:]
            return
        }
        let peers = (try? await gs.peers()) ?? []
        peersByIP = Dictionary(
            peers.map { ($0.addr, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Short node-key fingerprint for a guest's tunnel IP ("9c8d…4f21"),
    /// refreshing the peer map on a miss. Nil while the peer hasn't landed
    /// in the node's map yet — callers fall back to the IP.
    public func fingerprint(forIP ip: String) async -> String? {
        if peersByIP[ip] == nil { await refreshPeers() }
        return peersByIP[ip].map { ShareLinkFormat.keyFingerprint($0.key) }
    }

    private func close() async {
        await guestServer?.close()
        guestServer = nil
        token = nil
        peersByIP = [:]
    }
}
