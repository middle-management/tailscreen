import Foundation

/// Process-side voice pipeline: PCM in → AAC enc → RTP out, and RTP in →
/// AAC dec (per SSRC) → mixed PCM out. Hardware capture/playback glue is
/// in `MicCapture` (added in Task 7) which feeds this class.
///
/// Thread-safe via an internal serial queue: capture callbacks (audio
/// thread) and network callbacks (TailscaleKit reader task) call into
/// public methods which dispatch onto the queue. State only mutates on
/// the queue.
final class VoiceChannel: @unchecked Sendable {
    let localSSRC: UInt32
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set { queue.sync { _isMuted = newValue } }
    }

    /// Invoked on the internal queue every time the encoder produces an
    /// RTP packet. Caller should pass it to the network layer.
    private let onSend: (Data) -> Void

    /// Invoked on the internal queue every time the decoder produces a
    /// block of mixed PCM samples ready to render. The MicCapture glue
    /// schedules these into the playback engine.
    var onMixedPCM: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "VoiceChannel")
    private var _isMuted: Bool = true
    private let encoder: AACEncoder
    private let packetizer: AudioRTPPacketizer
    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: AACDecoder] = [:]

    init(localSSRC: UInt32, onSend: @escaping (Data) -> Void) throws {
        self.localSSRC = localSSRC
        self.onSend = onSend
        self.encoder = try AACEncoder()
        self.packetizer = AudioRTPPacketizer(ssrc: localSSRC)
    }

    /// Push exactly 1024 PCM samples (one AAC AU's worth) for outbound
    /// transmission. No-op when muted.
    func processOutboundFrame(_ pcm: [Float]) {
        queue.async {
            guard !self._isMuted else { return }
            do {
                guard let au = try self.encoder.encode(pcm: pcm) else { return }
                let packet = self.packetizer.packetize(au: au)
                self.onSend(packet)
            } catch {
                print("VoiceChannel: encode failed: \(error)")
            }
        }
    }

    /// Ingest one inbound RTP audio packet. Decodes per SSRC and emits
    /// PCM via `onMixedPCM`.
    func receive(_ packet: Data) {
        queue.async {
            guard let parsed = self.depacketizer.unpack(packet) else { return }
            // Drop our own loopback if the network somehow returned it.
            guard parsed.ssrc != self.localSSRC else { return }
            do {
                let decoder = try self.ensureDecoder(for: parsed.ssrc)
                let samples = try decoder.decode(au: parsed.au)
                if !samples.isEmpty {
                    self.onMixedPCM?(samples)
                }
            } catch {
                print("VoiceChannel: decode failed for ssrc=\(parsed.ssrc): \(error)")
            }
        }
    }

    /// Forget all per-SSRC decoders. Called when the share session ends
    /// so a future session starts fresh.
    func reset() {
        queue.async {
            self.decoders.removeAll()
        }
    }

    private func ensureDecoder(for ssrc: UInt32) throws -> AACDecoder {
        if let existing = decoders[ssrc] { return existing }
        let new = try AACDecoder()
        decoders[ssrc] = new
        return new
    }

#if DEBUG
    /// Drain the internal queue so test assertions can run synchronously
    /// after enqueuing outbound/inbound work.
    internal func flushForTesting() {
        queue.sync { }
    }
#endif
}
