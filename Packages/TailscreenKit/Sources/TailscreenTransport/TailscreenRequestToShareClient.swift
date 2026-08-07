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
/// parks rather than returning immediately and waiting for a dial-back. That
/// is the whole point of the design: a dial-back would answer whoever currently
/// holds the requester's address, whereas an answer on the open socket provably
/// reaches the process that asked.
///
/// Portable counterpart of the macOS `TailscreenMetadataService`
/// implementation, which was unreachable off macOS only because it lived in an
/// `import AppKit` file — nothing in the flow is platform-specific. Shaped
/// after `TailscreenMetadataClient`, which does the same dial/watchdog/drain
/// against the other half of the same wire pair.
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
        // Throws rather than reading as `.noAnswer`: no interface handle is a
        // fault on THIS machine, and reporting it as "they didn't reply" would
        // send someone to go ask a colleague why they ignored a request that
        // never left. Callers who genuinely cannot act on the difference —
        // `TsnetTransport.requestToShare` — collapse it themselves.
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let target = "\(host):\(port)"
        // Watchdogs because `tailscale_dial` and the connection init's actor
        // handshake can block indefinitely on an ACL-dropped SYN or a cold
        // netmap — with no error and no timeout of their own.
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
        // Drain frames until a `.shareResponse` arrives, the peer closes, or
        // the deadline passes. Anything else on the wire is ignored, which is
        // what makes this forward compatible with frames added later; the loop
        // itself is `FramedResponseDrain`, shared with
        // `TailscreenMetadataClient`.
        //
        // A 5 s poll, not 1 s: the wait here is two MINUTES — long enough for
        // somebody to walk back to their desk — and a one-second interval just
        // wakes 120 times to learn nothing. Still far above the 200 ms
        // dead-socket threshold the drain classifies against.
        //
        // Every failure mode arrives as nil and becomes `.noAnswer`, which is
        // the case that exists so a timeout, an EOF and a legacy peer are not
        // told apart in a UI that could not act on the difference.
        let accepted = await FramedResponseDrain.awaitResponse(
            on: conn, timeout: responseTimeout, pollMilliseconds: 5_000
        ) { message -> Bool? in
            guard case .shareResponse(let accepted) = message else { return nil }
            return accepted
        }
        guard let accepted else { return .noAnswer }
        return accepted ? .accepted : .declined
    }
}
