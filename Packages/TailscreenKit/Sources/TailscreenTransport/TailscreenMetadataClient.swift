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
                    logger: TSLogger()
                )
            }
            defer { Task { await conn.close() } }
            try await TailscalePeerDiscovery.withWatchdog(seconds: 5) {
                try await conn.connect()
            }
            try await conn.send(ScreenShareMessage.metadataRequest.encode())
            return await awaitMetadataResponse(on: conn, timeout: timeout)
        } catch {
            return nil
        }
    }

    /// Drain frames until a `.metadataResponse` arrives, the peer closes
    /// the connection, or `timeout` elapses; anything else on the wire is
    /// ignored. Same dead-socket-vs-poll-timeout classification as
    /// `TailscreenMetadataService.awaitShareResponse`.
    private static func awaitMetadataResponse(
        on conn: OutgoingConnection, timeout: TimeInterval
    ) async -> TailscreenMetadata? {
        var parser = ScreenShareMessageParser()
        let deadlineNs =
            DispatchTime.now().uptimeNanoseconds &+ UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            let recvStartNs = DispatchTime.now().uptimeNanoseconds
            do {
                let chunk = try await conn.receive(maximumLength: 16 * 1024, timeout: 1_000)
                if chunk.isEmpty { return nil }  // EOF — peer closed unanswered
                parser.append(chunk)
                while let message = parser.next() {
                    if case .metadataResponse(let metadata) = message {
                        return metadata
                    }
                }
                if parser.isCorrupt { return nil }
            } catch TailscaleError.readFailed {
                // Near-instant readFailed is a dead socket; a full-interval
                // one is just the poll timeout — keep waiting.
                let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                if ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                    return nil
                }
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) { print("[MetadataClient] \(message)") }
}
