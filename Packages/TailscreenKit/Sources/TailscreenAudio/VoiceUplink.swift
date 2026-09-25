import Foundation
import TailscreenProtocol

/// Everything between a microphone and a datagram on the wire: capture →
/// downmix/resample → 20 ms framing → Opus → RTP PT 98 → send.
///
/// One type for both endpoints: a sharer's and a viewer's voice are the same
/// stream in opposite directions, differing only in SSRC and destination
/// socket, so writing it twice would risk a mute that leaks on one side.
///
/// The host supplies the microphone and a `send` closure. It owns no socket
/// or thread of its own — the backend owns the capture thread, `send` runs on it.
public final class VoiceUplink: @unchecked Sendable {
    /// The sharer's own voice. `setSSRC` takes an optional rather than
    /// treating 0 as "unset": 0 is legitimate here, and a viewer emitting it
    /// would be impersonating the sharer.
    public static let sharerSSRC = RTPHeader.sharerVoiceSSRC

    private let microphone: MicrophoneCapturing
    private let pipeline: MicrophonePipeline
    private let send: (Data) -> Void
    private let lock = NSLock()
    /// Nil until the sharer assigns one. See `setSSRC`.
    private var ssrc: UInt32?
    private var packetizer: AudioRTPPacketizer?
    private var withheld = 0

    /// The capture stopped. Nil means the caller asked; an error means the
    /// device went away, and a host should stop claiming the microphone works.
    public var onStopped: ((Error?) -> Void)?
    /// An Opus frame failed to encode. One bad frame is not a reason to end a
    /// call, so the uplink keeps going; surfaced so it is not silent.
    public var onEncodeError: ((Error) -> Void)?

    public init(
        microphone: MicrophoneCapturing,
        encoder: OpusVoiceEncoder,
        send: @escaping (Data) -> Void
    ) {
        self.microphone = microphone
        self.pipeline = MicrophonePipeline(encoder: encoder)
        self.send = send

        pipeline.onAccessUnit = { [weak self] au in self?.emit(au) }
        pipeline.onEncodeError = { [weak self] error in self?.onEncodeError?(error) }
        microphone.onPCM = { [weak self] pcm, format in self?.pipeline.ingest(pcm, format: format) }
        microphone.onStopped = { [weak self] error in self?.onStopped?(error) }
        // Optional: a backend with no glitch signal simply never reports one.
        (microphone as? DiscontinuityReporting)?.onDiscontinuity = { [weak self] in
            self?.pipeline.noteDiscontinuity()
        }
    }

    /// Stop audio leaving this machine. Delegates to the pipeline, which drops
    /// at the source rather than encoding silence — see `MicrophonePipeline`.
    public var isMuted: Bool {
        get { pipeline.isMuted }
        set { pipeline.isMuted = newValue }
    }

    /// Set the SSRC this stream is sent under, or `nil` to hold.
    ///
    /// A viewer doesn't know its SSRC until the sharer's HELLO_ACK; an
    /// unassigned stream would go out as SSRC 0 (the sharer's reserved
    /// voice SSRC) and get dropped by the sharer's anti-spoof gate, so audio
    /// is withheld until an SSRC exists (`withheldPacketCount` tracks this).
    /// A sharer sets `VoiceUplink.sharerSSRC` once at construction.
    ///
    /// Changing it rebuilds the packetizer, restarting sequence numbers —
    /// correct, since a different SSRC is a different stream.
    public func setSSRC(_ ssrc: UInt32?) {
        lock.withLock {
            guard ssrc != self.ssrc else { return }
            self.ssrc = ssrc
            self.packetizer =
                ssrc.map {
                    AudioRTPPacketizer(ssrc: $0, payloadType: RTPHeader.voicePayloadType)
                }
        }
    }

    /// Encoded frames dropped for want of an SSRC.
    public var withheldPacketCount: Int { lock.withLock { withheld } }

    /// Start capturing. Throws whatever the backend throws when the device
    /// cannot be opened — a host should treat that as "no microphone" and say
    /// so, not retry silently.
    public func start() throws {
        try microphone.start()
    }

    /// Stop capturing and drop carried state, so a later session does not open
    /// with the tail of this one.
    public func stop() {
        microphone.stop()
        pipeline.reset()
    }

    /// Called on the capture thread, once per encoded 20 ms frame.
    private func emit(_ au: Data) {
        let packet = lock.withLock { () -> Data? in
            guard let packetizer else {
                withheld += 1
                return nil
            }
            return packetizer.packetize(au: au)
        }
        guard let packet else { return }
        send(packet)
    }
}
