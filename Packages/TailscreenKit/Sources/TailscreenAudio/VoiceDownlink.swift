import Foundation
import TailscreenProtocol

/// The receiving half of the voice path: RTP in, 48 kHz mono PCM out, one
/// independent Opus decoder per SSRC.
///
/// The inverse of `VoiceUplink` and, like it, one type for both endpoints. A
/// viewer decodes the sharer's voice (SSRC 0), the shared system audio
/// (SSRC 1) and every other viewer's relayed voice; a sharer decodes its
/// viewers'. Same demux, same per-stream state, so the sharer hosts on Linux
/// and Windows get it by construction rather than by growing a second copy —
/// which is what `ViewerSession` had inline before this, and why a sharer on
/// those platforms could be heard but could not hear.
///
/// Emits PCM tagged with its SSRC rather than mixing: who is speaking is
/// information the host needs (to route system audio to a different node than
/// voice, to show a speaking indicator) and mixing throws it away irreversibly.
///
/// **Not** thread-safe: driven from the host's receive loop, which is serial.
public final class VoiceDownlink {
    /// Concurrent voices to keep decoders for.
    ///
    /// A bound, not a capacity guess. Each SSRC allocates an Opus decoder, and
    /// the SSRC is a field in a datagram from the network — so an unbounded map
    /// is a remote allocation primitive. 32 is far above any real call and far
    /// below anything that matters for memory.
    public static let maxConcurrentVoices = 32

    /// Decoded 48 kHz mono PCM, tagged with the SSRC it came from.
    public var onPCM: ((UInt32, [Float]) -> Void)?

    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: OpusVoiceDecoder] = [:]
    /// Ingest ordinal of each SSRC's last packet, for eviction. A counter
    /// rather than a clock so the behaviour is deterministic and testable, and
    /// because nothing here needs to know what time it is.
    private var lastSeen: [UInt32: UInt64] = [:]
    private var ingestCount: UInt64 = 0

    public init() {}

    /// Feed one audio RTP datagram (PT 98 or 99). Anything else decodes to nil
    /// and is dropped.
    public func ingest(_ packet: Data) {
        guard let parsed = depacketizer.unpack(packet) else { return }
        ingestCount &+= 1
        lastSeen[parsed.ssrc] = ingestCount

        let decoder: OpusVoiceDecoder
        if let existing = decoders[parsed.ssrc] {
            decoder = existing
        } else {
            evictIfFull()
            guard let fresh = try? OpusVoiceDecoder() else { return }
            decoders[parsed.ssrc] = fresh
            decoder = fresh
        }
        guard let pcm = try? decoder.decode(au: parsed.au), !pcm.isEmpty else { return }
        onPCM?(parsed.ssrc, pcm)
    }

    /// Drop every decoder — a new session, or a sharer switch.
    public func reset() {
        decoders.removeAll()
        lastSeen.removeAll()
        ingestCount = 0
    }

    /// Live decoders. Exposed so a test can see the bound hold, which is the
    /// only way to observe it.
    public var voiceCount: Int { decoders.count }

    /// Whether this SSRC currently holds a decoder.
    ///
    /// The only way to see *which* stream eviction took. Without it a test can
    /// assert the map stayed bounded while the policy evicts precisely the
    /// wrong stream, which is a green check over a call where whoever is
    /// talking is the one being cut off.
    func hasVoice(_ ssrc: UInt32) -> Bool { decoders[ssrc] != nil }

    /// Make room by dropping the stream that has gone longest without a packet.
    ///
    /// Eviction rather than refusal: refusing the newcomer would silence a real
    /// participant permanently the moment the map filled, and the map fills
    /// with *stale* entries — people who left, or a peer cycling SSRCs. The
    /// quietest stream is the right one to forget, and if it speaks again it
    /// simply gets a fresh decoder (one lost frame while Opus re-converges).
    private func evictIfFull() {
        guard decoders.count >= Self.maxConcurrentVoices else { return }
        guard
            let stalest = decoders.keys.min(by: { (lastSeen[$0] ?? 0) < (lastSeen[$1] ?? 0) })
        else { return }
        decoders.removeValue(forKey: stalest)
        lastSeen.removeValue(forKey: stalest)
    }
}
