import Foundation
import TailscaleKit
import TailscreenProtocol

/// One-shot TCP/7447 "come watch my share" (spec §13.3): dial a peer, send
/// `.inviteToView`, and hold the connection open for the `.shareResponse`.
///
/// `.accepted` means the invitee will connect as a viewer to the address
/// this call dialled from; the caller should pre-approve that peer
/// (TS-MET-026). A peer on an older build drops the unknown byte, which
/// reads as `.noAnswer`.
public enum TailscreenInviteToViewClient {
    /// - Parameter responseTimeout: matches Ask to Share's wait and the
    ///   invitee's row expiry, so neither side outlives the other.
    public static func invite(
        toIP host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        from hostname: String,
        via node: TailscaleNode,
        responseTimeout: TimeInterval = 120
    ) async throws -> ShareRequestOutcome {
        try await TailscreenRequestToShareClient.ask(
            .inviteToView(fromHostname: hostname), toIP: host, port: port, via: node,
            responseTimeout: responseTimeout, logPrefix: "InviteToView")
    }
}
