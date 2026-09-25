import Foundation
import TailscaleKit
import TailscreenProtocol

/// How a peer answered "please share your screen".
///
/// `noAnswer` is deliberately one case rather than several. From the asker's
/// side a peer that is away, a peer that closed the window, and a peer running
/// a build old enough to drop the unknown `.shareResponse` byte are the same
/// situation: nobody said no, and nothing is going to happen. Splitting them
/// would put a distinction in the UI that the asker cannot act on differently.
public enum ShareRequestOutcome: Sendable, Equatable {
    case accepted
    case declined
    case noAnswer
}

/// One-shot TCP/7447 "would you share your screen?": dial a peer, send
/// `.requestToShare`, and hold the connection open for the `.shareResponse`.
///
/// The answer rides **the connection the request arrived on**, so this call
/// parks rather than returning immediately and waiting for a dial-back — a
/// dial-back would answer whoever currently holds the requester's address.
///
/// Shaped after `TailscreenMetadataClient`, the other half of the same wire
/// pair.
public enum TailscreenRequestToShareClient {
    /// - Parameter responseTimeout: how long to hold the connection open. The
    ///   default matches macOS's: long enough for somebody to notice a banner
    ///   and walk back to their desk, and short enough that a forgotten request
    ///   does not pin a connection for the session.
    public static func requestToShare(
        toIP host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        from hostname: String,
        via node: TailscaleNode,
        responseTimeout: TimeInterval = 120
    ) async throws -> ShareRequestOutcome {
        // Throws rather than reading as `.noAnswer`: no interface handle is
        // a fault on THIS machine, not "they didn't reply".
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let target = "\(host):\(port)"
        // Watchdogs: dial and the connection init's handshake can block
        // indefinitely on an ACL-dropped SYN or a cold netmap.
        let conn = try await TailscalePeerDiscovery.withWatchdog(seconds: 5) {
            try await OutgoingConnection(
                tailscale: tailscaleHandle,
                to: target,
                proto: .tcp,
                logger: PrintLogSink(prefix: "RequestToShare")
            )
        }
        defer { Task { await conn.close() } }
        try await TailscalePeerDiscovery.withWatchdog(seconds: 8) {
            try await conn.connect()
        }
        try await conn.send(
            ScreenShareMessage.requestToShare(fromHostname: hostname).encode())
        // Drain until `.shareResponse`, close, or deadline; other frames are
        // ignored (forward compatible). 5s poll, not 1s: the wait is two
        // minutes, so a 1s interval would wake 120 times for nothing.
        //
        // The closure yields the OUTCOME, not the wire's bool, so the drain's
        // "no match yet" nil and a decline stay distinct.
        let outcome = await FramedResponseDrain.awaitResponse(
            on: conn, timeout: responseTimeout, pollMilliseconds: 5_000
        ) { message -> ShareRequestOutcome? in
            guard case .shareResponse(let accepted) = message else { return nil }
            return accepted ? .accepted : .declined
        }
        return outcome ?? .noAnswer
    }
}
