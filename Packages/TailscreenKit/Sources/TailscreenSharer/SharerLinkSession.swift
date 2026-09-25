// The sharer's link (share-by-token) half as one portable object: guest node
// lifecycle, the attach/detach handshake with the server, New Link rotation,
// and the deny→tunnel-evict mapping. All three hosts drive this one; each
// host still publishes its own mirrors (token, peer map, busy flag) and
// wires `server.onGuestViewerDenied` → `evict(ip:)`.
//
// An actor, since every host calls it from async context (the guest node's
// DERP bootstrap blocks on the network) and hosts guard themselves
// differently otherwise (@MainActor / a lock).

import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

public enum SharerLinkError: Error, Sendable {
    /// The server refused the listener — the share stopped (or already has
    /// a guest listener) while the guest node was coming up. Nothing was
    /// adopted; session closed the socket and node.
    case attachRefused
    /// Another attempt claimed the session while this one was bootstrapping.
    /// Nothing of this attempt survives; callers that are themselves stale
    /// should swallow it.
    case superseded
}

public actor SharerLinkSession {
    private var guestServer: (any GuestLinkNode)?
    /// Tunnel IP → admitted guest peer, refreshed lazily. Public because a
    /// host that renders guest rows synchronously (e.g. from inside a
    /// SwiftUI body) can't `await`; call `refreshPeers()` or
    /// `fingerprint(forIP:)` for a current read.
    public private(set) var peersByIP: [String: GuestPeer] = [:]
    /// The live link's token — non-nil exactly while the guest node is up.
    public private(set) var token: String?
    /// Every mint takes the next claim before its first await, every
    /// teardown too — this is what invalidates a mint still in flight, since
    /// `guestServer` alone (written last) can't answer "still unclaimed?"
    /// across an actor's suspension points.
    private var claim: UInt64 = 0
    /// Which server owns the live link, and which owns the in-flight mint —
    /// lets a stop invalidate only its own attempt, not a replacement's.
    private var owner: ObjectIdentifier?
    private var claimOwner: ObjectIdentifier?
    private let logger: LogSink?
    /// How a node is made. Tests pass a fake whose calls can be held open —
    /// the only way to observe the orderings below (`SharerLinkSessionTests`).
    private let makeNode: @Sendable (String?, LogSink?) throws -> any GuestLinkNode

    public init(
        logger: LogSink? = nil,
        makeNode: (@Sendable (String?, LogSink?) throws -> any GuestLinkNode)? = nil
    ) {
        self.logger = logger
        self.makeNode =
            makeNode ?? { relay, log in try LiveGuestLinkNode(relayMapURL: relay, logger: log) }
    }

    /// Mint a link on a running share: guest node up, its listener attached
    /// as the server's guest socket, token returned. Blocks for the relay
    /// bootstrap. Idempotent — an already-live link returns its token.
    public func enable(
        on server: any GuestLinkServer,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        let id = ObjectIdentifier(server)
        if let token, guestServer != nil {
            // Idempotent only for the share that owns this link — engines
            // publish stopped state before their teardown reaches this actor,
            // so a replacement share arriving here must not get handed a
            // token whose server the delayed teardown is about to close.
            if owner == id { return token }
            await close()
        }
        claim &+= 1
        let mine = claim
        claimOwner = id
        let gs = try makeNode(relayMapURL, logger)
        try await gs.startNode()
        let pl = try await gs.openPacketRoute(port: port)
        guard server.attachGuestPacket(pl) else {
            // The share raced to a stop (or already holds a guest listener):
            // close the socket rather than leave a live token with no share.
            await pl.close()
            await gs.closeNode()
            throw SharerLinkError.attachRefused
        }
        // TCP control channel for guest annotations/remote control.
        // Fail-soft — video/voice still flow without it. Server owns
        // stopping it (detach and share-stop both close the adopted channel).
        do {
            let control = try await gs.openControlRoute(port: port)
            if !server.attachGuestControl(control) {
                await control.stop()
            }
        } catch {
            logger?.log(
                "Guest TCP control channel unavailable (\(error)) — link carries video/voice only")
        }
        let minted = try await gs.mintToken()
        // The share may have stopped anywhere in the bootstrap above; the
        // stop took a claim, so this one no longer holds it if so.
        guard claim == mine else {
            await gs.closeNode()
            throw SharerLinkError.superseded
        }
        guestServer = gs
        token = minted
        owner = id
        claimOwner = nil
        logger?.log("Share link active")
        return minted
    }

    /// Mint a link for a share that has **no tsnet node at all** — the
    /// signed-out, link-only share.
    ///
    /// Mirror image of `enable`: here the guest node IS the transport, so it
    /// must exist before the server starts (`startGuestOnly` takes the
    /// listeners as its only sockets). Throws with nothing left running: a
    /// half-started link-only share must not leave a live token behind.
    public func startLinkOnly(
        on server: any GuestLinkServer,
        filterData: Data?,
        quality: QualitySettings = .default,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        let id = ObjectIdentifier(server)
        if let token, guestServer != nil {
            if owner == id { return token }
            await close()
        }
        claim &+= 1
        let mine = claim
        claimOwner = id
        let gs = try makeNode(relayMapURL, logger)
        do {
            try await gs.startNode()
            let pl = try await gs.openPacketRoute(port: port)
            // TCP side for guest annotations/remote control; fail-soft as
            // in `enable`.
            var control: (any GuestControlRoute)?
            do {
                control = try await gs.openControlRoute(port: port)
            } catch {
                logger?.log(
                    "Guest TCP control channel unavailable (\(error)) — link carries video/voice only"
                )
            }
            try await server.startGuestOnlyShare(
                filterData: filterData,
                quality: quality,
                packet: pl,
                control: control)
            let minted = try await gs.mintToken()
            // The head guard was read before several awaits; a stop (or a
            // stop-then-start) landing in that window means somebody else
            // owns the session now, so publishing here would leak their node.
            guard claim == mine else { throw SharerLinkError.superseded }
            guestServer = gs
            token = minted
            owner = id
            claimOwner = nil
            logger?.log("Link-only share active — the link is the only way in")
            return minted
        } catch {
            // All-or-nothing including the server: `startGuestOnly` marks
            // itself running before the capture backend can fail, so a throw
            // after that leaves a live server nothing else references.
            // Stopping a never-started server is a no-op, safe on early legs.
            await server.stopServer()
            await gs.closeNode()
            throw error
        }
    }

    /// Kill the link on a still-running share: detach first (each guest
    /// gets HELLO_DENY + SERVER_BYE through the still-open guest socket),
    /// then close the node — the token is dead forever. No-op with no link.
    public func disable(on server: (any GuestLinkServer)?) async {
        guard guestServer != nil || token != nil else { return }
        await server?.detachGuestPacket()
        await close()
        logger?.log("Share link stopped — token dead")
    }

    /// New Link: the old token dies the moment this starts (current guests
    /// drop with it), and a fresh node key mints a fresh token.
    public func rotate(
        on server: any GuestLinkServer,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        await disable(on: server)
        return try await enable(on: server, relayMapURL: relayMapURL, port: port)
    }

    /// The share ended: the server's own stop already closed the listener
    /// and told every guest, so only the node is left to tear down.
    ///
    /// `mintedToken` lets a *stale* attempt unwind without collateral: the
    /// node closes only if it's still the live one, so a replacement share
    /// that minted its own link in the meantime keeps it. Omit for the
    /// ordinary stop. Returns whether anything was actually closed.
    @discardableResult
    public func teardown(
        for server: (any GuestLinkServer)? = nil,
        mintedToken: String? = nil
    ) async -> Bool {
        // Invalidate any mint still in flight first, even before a token
        // exists — else a stop landing between `enable` attaching its
        // listener and returning a token could still publish onto an idle
        // app. With a server, scoped to the mint IT owns (a stale share's
        // stop must not cancel a replacement's bootstrap); without one,
        // unconditional.
        if let server {
            if claimOwner == ObjectIdentifier(server) {
                claim &+= 1
                claimOwner = nil
            }
        } else {
            claim &+= 1
            claimOwner = nil
        }
        if let mintedToken, token != mintedToken { return false }
        guard guestServer != nil || token != nil else { return false }
        await close()
        return true
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
            try await gs.evictPeer(key: peer.key)
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
        let peers = (try? await gs.peerList()) ?? []
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

    /// Order matters: take the claim and blank state FIRST, then await the
    /// node's close. Closing first would leave `token`/`guestServer` readable
    /// across that suspension, letting a `startLinkOnly` landing there hand a
    /// replacement share the dying link's token.
    private func close() async {
        claim &+= 1
        claimOwner = nil
        owner = nil
        let gs = guestServer
        guestServer = nil
        token = nil
        peersByIP = [:]
        await gs?.closeNode()
    }
}
