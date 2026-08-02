import AppKit
import Foundation
import TailscaleKit

// TailscreenMetadata / TailscreenRequest live in TailscreenWireTypes.swift
// (platform-portable, part of TailscreenProtocol).

/// Service for managing Tailscreen metadata and requests
@MainActor
class TailscreenMetadataService: ObservableObject {
    @Published var currentMetadata: TailscreenMetadata?
    @Published var pendingRequests: [PendingRequest] = []

    /// Cap on the pending request-to-share banner set. Each incoming
    /// request pins a 120 s awaiting-response TCP connection on the
    /// requester's side and a banner row here; without a cap a peer flood
    /// (varying the wire-claimed hostname to defeat coalescing) could stack
    /// unbounded rows. New distinct requesters past the cap are dropped.
    static let maxPendingRequests = 16

    struct PendingRequest: Identifiable {
        let id: UUID
        let fromHostname: String
        let timestamp: Date
        /// `TailscreenControlListener` connection UUID the request arrived
        /// on. The accept/decline response is sent back on this connection
        /// (best-effort — the requester may have given up and closed it).
        /// nil for legacy call sites that never learned the connection.
        let connectionID: UUID?
        /// Trust-worthy coalescing key — the requester's source IP (port
        /// stripped) when the transport reported it, else `host:<hostname>`.
        /// Deliberately NOT the raw wire-claimed hostname: an attacker can
        /// vary that to stack banner rows and pin one connection each.
        let sourceKey: String

        init(
            id: UUID = UUID(), fromHostname: String, timestamp: Date,
            connectionID: UUID? = nil, sourceKey: String = ""
        ) {
            self.id = id
            self.fromHostname = fromHostname
            self.timestamp = timestamp
            self.connectionID = connectionID
            self.sourceKey = sourceKey
        }
    }

    /// Get current screen resolution
    private func getCurrentScreenResolution() -> TailscreenMetadata.ScreenResolution {
        guard let screen = NSScreen.main else {
            return TailscreenMetadata.ScreenResolution(width: 1920, height: 1080)
        }

        let frame = screen.frame
        return TailscreenMetadata.ScreenResolution(
            width: Int(frame.width),
            height: Int(frame.height)
        )
    }

    /// Update metadata when sharing starts
    func updateMetadata(isSharing: Bool, shareName: String? = nil) {
        let hostname = Host.current().localizedName ?? "Unknown"
        let name = shareName ?? "\(hostname)'s Screen"

        currentMetadata = TailscreenMetadata(
            shareName: name,
            hostname: hostname,
            screenResolution: getCurrentScreenResolution(),
            isSharing: isSharing,
            timestamp: Date()
        )
    }

    /// Handle incoming request to share. Coalesces repeated requests
    /// from the same peer — a flaky network or a peer that retries
    /// shouldn't stack N identical banner rows. The existing entry's
    /// timestamp is refreshed so the row stays sorted as "newest", and its
    /// connection ID is replaced with the retry's (the old connection is
    /// likely dead, and the response should ride the freshest one).
    func handleRequestToShare(from hostname: String, sourceAddr: String? = nil, connectionID: UUID? = nil) {
        // Coalesce on the source identity, not the wire-claimed hostname —
        // retries dial a fresh connection (new ephemeral port), so we key on
        // the peer IP; fall back to the hostname only when no address was
        // reported (legacy path).
        let key = sourceAddr.map { Self.sourceKey(from: $0) } ?? "host:\(hostname)"
        if let idx = pendingRequests.firstIndex(where: { $0.sourceKey == key }) {
            let existing = pendingRequests.remove(at: idx)
            pendingRequests.append(
                PendingRequest(
                    id: existing.id, fromHostname: hostname, timestamp: Date(),
                    connectionID: connectionID ?? existing.connectionID, sourceKey: key)
            )
            return
        }
        // Bound the set: once the sharer's backlog is full, drop new distinct
        // requesters rather than growing unbounded under a flood.
        guard pendingRequests.count < Self.maxPendingRequests else { return }
        pendingRequests.append(
            PendingRequest(
                fromHostname: hostname, timestamp: Date(), connectionID: connectionID, sourceKey: key))
    }

    /// Strip the trailing `:port` (and IPv6 brackets) so retries from the
    /// same peer — which dial a fresh source port each time — coalesce onto
    /// one banner row. Same split-on-last-colon rule the server uses.
    nonisolated static func sourceKey(from addr: String) -> String {
        guard let lastColon = addr.lastIndex(of: ":") else { return addr }
        var ip = String(addr[..<lastColon])
        if ip.hasPrefix("["), ip.hasSuffix("]") {
            ip = String(ip.dropFirst().dropLast())
        }
        return ip
    }

    /// Clear a pending request
    func clearRequest(_ request: PendingRequest) {
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Clear all pending requests
    func clearAllRequests() {
        pendingRequests.removeAll()
    }

    /// The metadata served to a peer's `.metadataRequest` (the sharing-
    /// status filter's fetch half). Falls back to an idle, not-sharing
    /// snapshot when no share has run this session (`currentMetadata` is
    /// nil until the first `updateMetadata` call) — answering is what lets
    /// a requester distinguish "reachable but not sharing" from "no
    /// answer" (offline / legacy build).
    func wireMetadata() -> TailscreenMetadata {
        if let current = currentMetadata { return current }
        return TailscreenMetadata(
            shareName: "",
            hostname: Host.current().localizedName ?? "Unknown",
            screenResolution: getCurrentScreenResolution(),
            isSharing: false,
            timestamp: Date()
        )
    }

    /// Create metadata JSON for API response
    func getMetadataJSON() throws -> Data {
        guard let metadata = currentMetadata else {
            throw NSError(
                domain: "TailscreenMetadata", code: 1, userInfo: [NSLocalizedDescriptionKey: "No metadata available"])
        }
        return try JSONEncoder().encode(metadata)
    }

    /// Send a request-to-share prompt to `toIP` over the framed control
    /// protocol on the peer's tsnet listener, then hold the connection open
    /// waiting for the peer's `.shareResponse` frame so the requester learns
    /// whether they were accepted or declined. Timeout / EOF map to
    /// `.noAnswer` — which is also exactly what an old peer that doesn't
    /// speak `shareResponse` produces. The receive side picks the request up
    /// through `TailscreenControlListener.onRequestToShare` and answers on
    /// this same connection.
    ///
    /// Both the `OutgoingConnection` init and `connect()` are wrapped in
    /// `TailscalePeerDiscovery.withWatchdog` because `tailscale_dial` (and
    /// the init's actor handshake) can block indefinitely on ACL-dropped
    /// SYNs or a cold netmap — without the watchdog the UI Task hangs
    /// forever and the error never surfaces. The response wait itself needs
    /// no watchdog: it polls `receive` with a bounded per-call timeout.
    @discardableResult
    func sendRequestToShareAwaitingResponse(
        toIP host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        from hostname: String,
        via node: TailscaleNode,
        responseTimeout: TimeInterval = 120
    ) async throws -> ShareRequestOutcome {
        // Forwards to the portable client, which is this method's own body
        // moved into `TailscreenTransport` so the Linux and Windows apps could
        // ask too. Kept as a method rather than deleted because every call
        // site here reads better against the service that owns the other half
        // of this conversation — `pendingRequests` and `handleRequestToShare`
        // are right here.
        //
        // One behaviour improved in the move: an EOF now settles the wait
        // immediately instead of polling on to the full timeout. A peer that
        // closes without answering used to cost the requester two minutes of
        // "asking…" for an answer that was never coming.
        try await TailscreenRequestToShareClient.requestToShare(
            toIP: host, port: port, from: hostname, via: node,
            responseTimeout: responseTimeout)
    }
}

// `ShareRequestOutcome` now lives in `TailscreenTransport` beside the client
// that produces it, and reaches this file through `ProtocolReexports`. The
// local copy was deleted rather than renamed: two identical enums, one of them
// shadowing the other through an `@_exported import`, is the ambiguity
// CLAUDE.md warns about for `ProfileStore` — and here there was no reason for
// a second one to exist.
