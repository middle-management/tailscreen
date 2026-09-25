import Foundation
import TailscaleKit

/// One byte-stream shape for the framed TCP control channel, whichever
/// tunnel carried it: the tailnet (`OutgoingConnection`) or a guest tunnel
/// (`GuestClientNode.dial`, an `IncomingConnection` — guest fds are
/// bit-compatible with tsnet fds). Names the overlap so channel code is
/// written once instead of per connection type.
///
/// `remoteAddress` is deliberately absent — only the sharer's accept side
/// needs it, and that side always holds the concrete `IncomingConnection`.
public protocol FramedControlChannel: Actor {
    func send(_ data: Data) throws
    func receive(maximumLength: Int, timeout: Int32) async throws -> Data
    func close()
}

extension OutgoingConnection: FramedControlChannel {}
extension IncomingConnection: FramedControlChannel {}
