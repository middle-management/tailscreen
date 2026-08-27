// The share's datagram sockets: the tailnet listener every share has, plus
// the optional guest (share-by-token) listener from a `GuestServerNode`.
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
    /// The tailnet UDP listener (port 7447 on the tsnet node).
    let primary: PacketListener
    /// The guest UDP listener (port 7447 inside the guest node's own
    /// netstack), when the share is also shared by token.
    let guest: PacketListener?
    /// Reports whether addr was first seen on the guest listener.
    let isGuestAddr: @Sendable (String) -> Bool

    /// Send one datagram to addr via the listener its flows live on.
    /// Matches `PacketListener.send`'s signature so existing call sites
    /// (`pl.send(x, to: addr)`) compile unchanged against this type.
    func send(_ data: Data, to addr: String) async throws {
        if let guest, isGuestAddr(addr) {
            try await guest.send(data, to: addr)
        } else {
            try await primary.send(data, to: addr)
        }
    }
}
