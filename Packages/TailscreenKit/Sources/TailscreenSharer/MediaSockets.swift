// The share's datagram sockets: the tailnet listener a signed-in share
// has, and/or the guest (share-by-token) listener from a `GuestServerNode`
// — at least one of the two, never neither (the `media` snapshot returns
// nil for a stopped share instead of building an empty pair).
//
// One value, one `send`, so the ~15 fan-out/ACK/denial send sites in
// `TailscaleScreenShareServer` stay written exactly as before — the routing
// by destination happens here. Guest addresses can never collide with
// tailnet ones (they are ULA addresses derived from guest node keys, in a
// separate netstack), but membership is still decided explicitly: an addr
// is a guest iff its datagrams arrive on the guest listener, recorded by
// the guest receive loop for the life of the share.

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
    /// datagram in a `.mediaDatagram` frame on the viewer's own framed TCP
    /// connection and reports true. False means addr has no stream route
    /// and the datagram falls through to the UDP listeners below. Checked
    /// FIRST because a stream addr is synthetic (`ip:tcp-…`) — it never
    /// names a real UDP flow, and sending it there would silently vanish.
    let sendViaStream: @Sendable (Data, String) async -> Bool

    /// Send one datagram to addr via the listener its flows live on.
    /// Matches `PacketListener.send`'s signature so existing call sites
    /// (`pl.send(x, to: addr)`) compile unchanged against this type.
    /// With no primary every addr is a guest addr by construction, so the
    /// guest socket carries everything.
    func send(_ data: Data, to addr: String) async throws {
        if await sendViaStream(data, addr) { return }
        if let guest, primary == nil || isGuestAddr(addr) {
            try await guest.send(data, to: addr)
        } else if let primary {
            try await primary.send(data, to: addr)
        }
    }
}
