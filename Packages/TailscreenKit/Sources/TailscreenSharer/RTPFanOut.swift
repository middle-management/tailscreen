// Pure packet-shaping statics for `TailscaleScreenShareServer`'s RTP
// fan-out: per-viewer send-chain enqueue gate and RTP header rewrite.

import Foundation

extension TailscaleScreenShareServer {
    /// Per-viewer send-chain gate: enqueue only while fewer than `cap` are
    /// already queued behind a stalled send (drop-newest past the cap).
    public static func shouldEnqueue(queued: Int, cap: Int) -> Bool {
        queued < cap
    }

    /// Overwrites bytes 2-3 (sequence) and 8-11 (SSRC) of an RTP packet
    /// in-place, avoiding re-encoding the whole header per viewer. Open-coded
    /// big-endian stores since TailscreenProtocol's `appendBE`/`readBE`
    /// don't cross the module boundary.
    public static func rewriteRTPHeader(_ packet: inout Data, sequence: UInt16, ssrc: UInt32) {
        packet[2] = UInt8((sequence >> 8) & 0xFF)
        packet[3] = UInt8(sequence & 0xFF)
        packet[8] = UInt8((ssrc >> 24) & 0xFF)
        packet[9] = UInt8((ssrc >> 16) & 0xFF)
        packet[10] = UInt8((ssrc >> 8) & 0xFF)
        packet[11] = UInt8(ssrc & 0xFF)
    }
}
