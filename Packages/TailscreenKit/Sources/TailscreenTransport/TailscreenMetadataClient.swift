import Foundation
import TailscaleKit
import TailscreenProtocol

/// One-shot TCP/7447 metadata query: dial a peer, send `.metadataRequest`,
/// and read the `.metadataResponse` off the same connection. This is the
/// fetch half of the peer list's sharing-status filter — deliberately lazy
/// (the caller decides when to dial; typically on menu open) because in a
/// large tailnet this is the only per-peer network cost the peer list has.
///
/// All failure modes collapse to `nil` — "status unknown": dial/connect
/// failure, timeout, EOF, and a legacy peer that drops the unknown
/// `.metadataRequest` byte on the floor (its parser skips unknown types, so
/// the requester simply never gets an answer). Callers must treat nil as
/// unknown, not as "not sharing".
public enum TailscreenMetadataClient {
    public static func fetchMetadata(
        fromIP host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        via node: TailscaleNode,
        timeout: TimeInterval = 4
    ) async -> TailscreenMetadata? {
        guard let tailscaleHandle = await node.tailscale else { return nil }
        let target = "\(host):\(port)"
        do {
            // Watchdogs for the same reason `sendRequestToShareAwaitingResponse`
            // has them: `tailscale_dial` (and the init's actor handshake) can
            // block indefinitely on ACL-dropped SYNs or a cold netmap.
            let conn = try await TailscalePeerDiscovery.withWatchdog(seconds: 5) {
                try await OutgoingConnection(
                    tailscale: tailscaleHandle,
                    to: target,
                    proto: .tcp,
                    logger: PrintLogSink(prefix: "MetadataClient")
                )
            }
            defer { Task { await conn.close() } }
            try await TailscalePeerDiscovery.withWatchdog(seconds: 5) {
                try await conn.connect()
            }
            try await conn.send(ScreenShareMessage.metadataRequest.encode())
            // Drain frames until a `.metadataResponse` arrives, the peer
            // closes, or `timeout` elapses; anything else on the wire is
            // ignored. The loop — including the dead-socket-vs-poll-timeout
            // classification — is `FramedResponseDrain`, shared with
            // `TailscreenRequestToShareClient`. A 1 s poll: the whole wait is
            // seconds, so a longer interval would round the timeout up.
            return await FramedResponseDrain.awaitResponse(
                on: conn, timeout: timeout, pollMilliseconds: 1_000
            ) { message in
                guard case .metadataResponse(let metadata) = message else { return nil }
                return metadata
            }
        } catch {
            return nil
        }
    }
}
