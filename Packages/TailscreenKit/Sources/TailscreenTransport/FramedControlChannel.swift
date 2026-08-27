import Foundation
import TailscaleKit

/// One byte-stream shape for the framed TCP control channel, whichever
/// tunnel carried it.
///
/// The viewer's back-channel dials the sharer over the tailnet
/// (`OutgoingConnection`) or over a share-by-token guest tunnel
/// (`GuestClientNode.dial`, which hands back an `IncomingConnection` —
/// guest fds are bit-compatible with tsnet fds, so the accepted-connection
/// type is the natural return there). The two actors already expose the
/// same three calls with the same shapes; this protocol names that overlap
/// so the channel code is written once instead of per connection type.
///
/// `remoteAddress` is deliberately absent: only the sharer's accept side
/// needs it (for admitted-viewer gating), and that side always holds the
/// concrete `IncomingConnection`.
public protocol FramedControlChannel: Actor {
    func send(_ data: Data) throws
    func receive(maximumLength: Int, timeout: Int32) async throws -> Data
    func close()
}

extension OutgoingConnection: FramedControlChannel {}
extension IncomingConnection: FramedControlChannel {}
