// Pure packet-shaping statics for `TailscaleScreenShareServer`'s RTP
// fan-out, moved verbatim out of TailscaleScreenShareServer.swift: the
// per-viewer send-chain enqueue gate and the per-viewer RTP header rewrite.
// No instance state, no locks, no callbacks.

import Foundation

extension TailscaleScreenShareServer {
    /// Pure per-viewer send-chain gate: enqueue a frame/packet only while
    /// fewer than `cap` are already queued behind a stalled send (drop-newest
    /// past the cap). Extracted so the drop policy — shared by the video and
    /// audio chains — is unit testable.
    public static func shouldEnqueue(queued: Int, cap: Int) -> Bool {
        queued < cap
    }

    /// Overwrites bytes 2-3 (sequence) and 8-11 (SSRC) of an RTP packet.
    /// Avoids re-encoding the whole header per viewer. Internal (not
    /// private) so the per-viewer rewrite is unit testable.
    ///
    /// The big-endian byte stores are open-coded on purpose: this is an
    /// in-place overwrite at fixed offsets, not an append, and
    /// TailscreenProtocol's internal `appendBE`/`readBE` helpers neither fit
    /// that shape nor cross the module boundary.
    public static func rewriteRTPHeader(_ packet: inout Data, sequence: UInt16, ssrc: UInt32) {
        packet[2] = UInt8((sequence >> 8) & 0xFF)
        packet[3] = UInt8(sequence & 0xFF)
        packet[8] = UInt8((ssrc >> 24) & 0xFF)
        packet[9] = UInt8((ssrc >> 16) & 0xFF)
        packet[10] = UInt8((ssrc >> 8) & 0xFF)
        packet[11] = UInt8(ssrc & 0xFF)
    }
}
