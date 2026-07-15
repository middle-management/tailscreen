import AppKit
import Foundation
import TailscaleKit

/// Metadata about a Tailscreen screen share
struct TailscreenMetadata: Codable, Sendable, Equatable {
    var version: String = "1.0"
    let shareName: String
    let hostname: String
    let screenResolution: ScreenResolution
    let isSharing: Bool
    let timestamp: Date
    /// Codec the sharer is currently encoding with. Optional for backward
    /// compat with older peers that omit the field — when missing, assume
    /// H.264 (the only codec older Tailscreen builds spoke). The viewer
    /// also auto-detects from the RTP payload type, so this is mainly
    /// informational for the UI.
    var videoCodec: VideoCodec?

    struct ScreenResolution: Codable, Sendable, Equatable {
        let width: Int
        let height: Int
    }
}

/// Request types for peer-to-peer communication
enum TailscreenRequest: Codable, Sendable {
    case requestToShare(from: String)
    case acceptShare
    case declineShare

    enum CodingKeys: String, CodingKey {
        case type, from
    }

    enum RequestType: String, Codable {
        case requestToShare
        case acceptShare
        case declineShare
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RequestType.self, forKey: .type)

        switch type {
        case .requestToShare:
            let from = try container.decode(String.self, forKey: .from)
            self = .requestToShare(from: from)
        case .acceptShare:
            self = .acceptShare
        case .declineShare:
            self = .declineShare
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .requestToShare(let from):
            try container.encode(RequestType.requestToShare, forKey: .type)
            try container.encode(from, forKey: .from)
        case .acceptShare:
            try container.encode(RequestType.acceptShare, forKey: .type)
        case .declineShare:
            try container.encode(RequestType.declineShare, forKey: .type)
        }
    }
}

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
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let target = "\(host):\(port)"
        let conn = try await TailscalePeerDiscovery.withWatchdog(seconds: 5) {
            try await OutgoingConnection(
                tailscale: tailscaleHandle,
                to: target,
                proto: .tcp,
                logger: TSLogger()
            )
        }
        try await TailscalePeerDiscovery.withWatchdog(seconds: 8) {
            try await conn.connect()
        }
        let frame = ScreenShareMessage.requestToShare(fromHostname: hostname).encode()
        try await conn.send(frame)
        let outcome = await Self.awaitShareResponse(on: conn, timeout: responseTimeout)
        await conn.close()
        return outcome
    }

    /// Drain frames off the request connection until a `.shareResponse`
    /// arrives, the peer closes the connection, or `timeout` elapses. The
    /// banner on the far side may sit unanswered for minutes (it's
    /// suppressed while the peer is busy), so the default timeout is
    /// generous; anything else on the wire is ignored.
    private static func awaitShareResponse(
        on conn: OutgoingConnection, timeout: TimeInterval
    ) async -> ShareRequestOutcome {
        var parser = ScreenShareMessageParser()
        let deadlineNs =
            DispatchTime.now().uptimeNanoseconds &+ UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            let recvStartNs = DispatchTime.now().uptimeNanoseconds
            do {
                let chunk = try await conn.receive(maximumLength: 16 * 1024, timeout: 5_000)
                parser.append(chunk)
                while let message = parser.next() {
                    if case .shareResponse(let accepted) = message {
                        return accepted ? .accepted : .declined
                    }
                }
            } catch TailscaleError.readFailed {
                // `OutgoingConnection.receive` throws readFailed for BOTH a
                // benign poll timeout AND a dead/closed fd (EOF returns
                // instantly). Elapsed time tells them apart — the same
                // classification the UDP receive loops use: a near-instant
                // readFailed is a dead socket (peer closed without
                // answering), so stop waiting instead of hot-spinning the
                // closed connection for the full timeout; a full-interval
                // one is just a poll timeout, so keep waiting.
                let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                if ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                    return .noAnswer
                }
                continue  // poll timeout — keep waiting for an answer
            } catch {
                return .noAnswer
            }
        }
        return .noAnswer
    }
}

/// Outcome of a request-to-share round-trip, as seen by the requester.
enum ShareRequestOutcome: Sendable, Equatable {
    /// The peer clicked Share — they're choosing what to share now.
    case accepted
    /// The peer clicked Decline.
    case declined
    /// The peer never answered within the timeout, or closed the connection
    /// without responding. Old Tailscreen builds that don't speak
    /// `shareResponse` always land here.
    case noAnswer
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) { print("[Metadata] \(message)") }
}
