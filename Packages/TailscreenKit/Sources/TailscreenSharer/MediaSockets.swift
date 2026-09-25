// The share's datagram sockets: the tailnet listener a signed-in share has,
// and/or the guest (share-by-token) listener from a `GuestServerNode` — at
// least one, never neither. One `send` routes by destination so the ~15
// fan-out/ACK/denial call sites in `TailscaleScreenShareServer` are
// unchanged. Guest addresses (ULA, derived from guest node keys) can't
// collide with tailnet ones, but membership is still decided explicitly by
// which listener the datagram arrived on.

import Foundation
import TailscaleKit

struct MediaSockets: Sendable {
    /// The tailnet UDP listener (port 7447 on the tsnet node). Nil for a
    /// guest-only (link-only, no sign-in) share.
    let primary: PacketListener?
    /// The guest UDP listener (port 7447 inside the guest node's own
    /// netstack), when the share is shared by token. For a guest-only
    /// share it is the only socket there is.
    let guest: PacketListener?
    /// Reports whether addr was first seen on the guest listener.
    let isGuestAddr: @Sendable (String) -> Bool
    /// Route for stream (reliable-transport, spec §2.2) viewers: wraps the
    /// datagram in a `.mediaDatagram` TCP frame, returns true. False falls
    /// through to UDP. Checked first — a stream addr is synthetic
    /// (`ip:tcp-…`) and would silently vanish if sent as UDP.
    let sendViaStream: @Sendable (Data, String) async -> Bool

    /// Send one datagram to addr via the listener its flows live on.
    /// Matches `PacketListener.send`'s signature so existing call sites
    /// compile unchanged.
    func send(_ data: Data, to addr: String) async throws {
        if await sendViaStream(data, addr) { return }
        if let guest, primary == nil || isGuestAddr(addr) {
            try await guest.send(data, to: addr)
        } else if let primary {
            try await primary.send(data, to: addr)
        }
    }
}
