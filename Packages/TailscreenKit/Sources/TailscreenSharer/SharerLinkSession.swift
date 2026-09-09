// The sharer's link (share-by-token) half as one portable object: the
// guest node's lifecycle, the attach/detach handshake with the server, New
// Link rotation, and the deny→tunnel-evict mapping. All three hosts drive
// this one — the macOS AppState grew the logic first (phase 4) and its copy
// is gone; what stays host-side is the published mirrors each hub renders
// from (a token, a peer map, a busy flag) and the one wire the session
// cannot make for you, `server.onGuestViewerDenied` → `evict(ip:)`.
//
// An actor: every host calls it from async context (the guest node's DERP
// bootstrap blocks for the network), and the hosts guard themselves
// differently (@MainActor on two of them, a lock on Windows) — an actor is
// the shape none of them has to adapt to.

import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

public enum SharerLinkError: Error, Equatable, Sendable {
    /// The server refused the listener — the share stopped (or already has
    /// a guest listener) while the guest node was coming up. Nothing was
    /// adopted; the session closed the socket and the node.
    case attachRefused
    /// Another attempt claimed the session while this one was bootstrapping
    /// — a stop and a fresh start inside the seconds a relay handshake
    /// takes. Nothing of this attempt survives: its node is closed and the
    /// server it was starting is stopped, so the winner's link is the only
    /// one live. Callers that are themselves stale should swallow it.
    case superseded
}

public actor SharerLinkSession {
    private var guestServer: (any GuestNodeProviding)?
    /// Tunnel IP → admitted guest peer, refreshed lazily. Supplies key
    /// fingerprints and the eviction lookup (`onGuestViewerDenied` reports
    /// an IP; `removePeer` wants the node key).
    ///
    /// Readable because a host that renders guest rows *synchronously* has
    /// to mirror it — the macOS roster asks for a fingerprint from inside a
    /// SwiftUI body, where an `await` is not available. `refreshPeers()`
    /// first if you need it current; `fingerprint(forIP:)` is the async
    /// path that does that for you.
    public private(set) var peersByIP: [String: GuestPeer] = [:]
    /// The live link's token — non-nil exactly while the guest node is up.
    public private(set) var token: String?
    /// Who owns the session right now. Every mint takes the next claim
    /// BEFORE its first await, and every teardown takes one too — which is
    /// what invalidates a mint still in flight. An actor yields at each
    /// await, so "is this session still unclaimed?" cannot be answered by
    /// reading `guestServer`: that field is written last, and the whole
    /// bootstrap runs in the gap.
    private var claim: UInt64 = 0
    private let logger: LogSink?
    /// How a mint gets its guest node. Defaults to the real one; a test
    /// passes a fake so the DERP handshake — and the suspension it hides —
    /// is something it can hold open on purpose.
    private let makeNode: GuestNodeFactory

    public init(logger: LogSink? = nil, makeNode: @escaping GuestNodeFactory = SharerLinkSession.realGuestNode) {
        self.logger = logger
        self.makeNode = makeNode
    }

    /// The factory every host installs: a `GuestServerNode` behind the seam.
    public static let realGuestNode: GuestNodeFactory = { relayMapURL, logger in
        try RealGuestNode(derpMapURL: relayMapURL, logger: logger)
    }

    /// Mint a link on a running share: guest node up, its listener attached
    /// as the server's guest socket, token returned. Blocks for the relay
    /// bootstrap. Idempotent — an already-live link returns its token.
    public func enable(
        on server: any GuestLinkServing,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        if let token, guestServer != nil { return token }
        claim &+= 1
        let mine = claim
        let gs = try makeNode(relayMapURL, logger)
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
            let control = try await gs.listenControl(port: port)
            if !server.attachGuestControlListener(control) {
                await control.stop()
            }
        } catch {
            logger?.log(
                "Guest TCP control channel unavailable (\(error)) — link carries video/voice only")
        }
        let minted = try await gs.token()
        // The share can have stopped anywhere in the bootstrap above: the
        // server's own stop closed the listener this attempt attached, and
        // publishing now would leave a live guest node and a token on an
        // idle app. The stop took a claim, so this one no longer holds it.
        guard claim == mine else {
            await gs.close()
            throw SharerLinkError.superseded
        }
        guestServer = gs
        token = minted
        logger?.log("Share link active")
        return minted
    }

    /// Mint a link for a share that has **no tsnet node at all** — the
    /// signed-out, link-only share the macOS hub offers from its welcome
    /// pane, now on the two swift-cross-ui hosts as well.
    ///
    /// The ordering is the mirror image of `enable`: there the server is
    /// already running and the guest listener is attached to it, whereas
    /// here the guest node IS the transport, so it has to exist before the
    /// server starts — `startGuestOnly` takes the listeners as its only
    /// sockets. Everything the guest half needs (eviction, rotation,
    /// teardown) is the same afterwards, which is why it lives here rather
    /// than being spelled out again in each engine.
    ///
    /// Throws with nothing left running: a half-started link-only share
    /// must not leave a live token behind a share that never happened.
    public func startLinkOnly(
        on server: any GuestLinkServing,
        filterData: Data?,
        quality: QualitySettings = .default,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        if let token, guestServer != nil { return token }
        claim &+= 1
        let mine = claim
        let gs = try makeNode(relayMapURL, logger)
        do {
            try await gs.start()
            let pl = try await gs.listenPacket(port: port)
            // The tunnel's TCP side: annotations and remote control for
            // guests. Fail-soft for the same reason as `enable` — a link
            // whose TCP bind failed still carries the video and voice that
            // are the substance of a share.
            var control: (any GuestControlChanneling)?
            do {
                control = try await gs.listenControl(port: port)
            } catch {
                logger?.log(
                    "Guest TCP control channel unavailable (\(error)) — link carries video/voice only"
                )
            }
            try await server.startGuestOnly(
                filterData: filterData,
                quality: quality,
                guestPacketListener: pl,
                guestControlListener: control)
            let minted = try await gs.token()
            // The head guard was read before several awaits, and an actor
            // yields at every one of them: a stop, or a stop and a fresh
            // start, landing inside this bootstrap means somebody else owns
            // the session now. Publishing here would overwrite their node —
            // leaking a live tunnel nothing can close, behind a token that
            // admits people to a server nobody references.
            guard claim == mine else { throw SharerLinkError.superseded }
            guestServer = gs
            token = minted
            logger?.log("Link-only share active — the link is the only way in")
            return minted
        } catch {
            // All-or-nothing, and the server is part of it: `startGuestOnly`
            // marks itself running and installs its receive/sweep loops
            // BEFORE the capture backend can fail, so a throw after that
            // point leaves a live server the caller is about to drop its
            // only reference to. Stopping a server that never started is a
            // no-op, so this is safe on the early legs too.
            await server.stop()
            await gs.close()
            throw error
        }
    }

    /// Kill the link on a still-running share: detach first (each guest
    /// gets HELLO_DENY + SERVER_BYE through the still-open guest socket),
    /// then close the node — the token is dead forever. No-op with no link.
    public func disable(on server: (any GuestLinkServing)?) async {
        guard guestServer != nil || token != nil else { return }
        await server?.detachGuestPacketListener()
        await close()
        logger?.log("Share link stopped — token dead")
    }

    /// New Link: the old token dies the moment this starts (current guests
    /// drop with it), and a fresh node key mints a fresh token.
    public func rotate(
        on server: any GuestLinkServing,
        relayMapURL: String? = nil,
        port: UInt16 = NetworkConfig.tailscreenPort
    ) async throws -> String {
        await disable(on: server)
        return try await enable(on: server, relayMapURL: relayMapURL, port: port)
    }

    /// The share ended: the server's own stop already closed the listener
    /// and told every guest, so only the node is left to tear down.
    ///
    /// `mintedToken` is how a *stale* attempt unwinds without collateral.
    /// Pass what `enable`/`startLinkOnly` handed back and the node is closed
    /// only if it is still the live one; a replacement share that minted its
    /// own link in the meantime keeps it. Omit it for the ordinary stop,
    /// where the caller is the current share by construction. Returns
    /// whether anything was actually closed, so a caller can tell whether
    /// the published token it is about to clear was still its own.
    @discardableResult
    public func teardown(mintedToken: String? = nil) async -> Bool {
        if let mintedToken, token != mintedToken { return false }
        let hadLink = guestServer != nil || token != nil
        await close()
        return hadLink
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

    /// Order is the whole of it: take the claim and blank the state FIRST,
    /// then await the node's close. Closing first leaves `token` and
    /// `guestServer` readable across that suspension, and a `startLinkOnly`
    /// that lands there takes the head guard's early return — handing a
    /// replacement share the token of the link being destroyed, with no
    /// node behind it. Taking the claim here is also what tells a mint
    /// still in flight that it no longer owns the session.
    private func close() async {
        claim &+= 1
        let gs = guestServer
        guestServer = nil
        token = nil
        peersByIP = [:]
        await gs?.close()
    }
}
