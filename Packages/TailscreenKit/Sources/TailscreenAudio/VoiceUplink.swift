import Foundation
import TailscreenProtocol

/// Everything between a microphone and a datagram on the wire: capture →
/// downmix/resample → 20 ms framing → Opus → RTP PT 98 → send.
///
/// One type for **both endpoints**. A sharer's voice and a viewer's voice are
/// the same stream in opposite directions — same codec, same payload type, same
/// framing — differing only in which SSRC they carry and which socket the host
/// hands the bytes to. Writing it twice would be writing the mute latch twice,
/// and a mute that works on one side and leaks on the other is the worst
/// possible split.
///
/// The host supplies the microphone (a `MicrophoneCapturing` backend it built,
/// or none at all if this machine cannot capture) and a `send` closure. It owns
/// no socket and no thread of its own — the backend owns the capture thread,
/// and `send` is called on it.
public final class VoiceUplink: @unchecked Sendable {
    /// The sharer's own voice. Fixed by the protocol, and the reason `setSSRC`
    /// takes an optional rather than treating 0 as "unset": 0 is a legitimate
    /// value here, and a viewer that emitted it would be impersonating the
    /// sharer.
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
        // Optional by design: a backend with no glitch signal conforms to
        // `MicrophoneCapturing` unchanged and simply never reports one.
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
    /// A **viewer** does not know its SSRC until the sharer's HELLO_ACK, which
    /// arrives some milliseconds after the socket is up and the person may
    /// already be talking. Sending in the meantime is not merely useless: an
    /// unassigned stream would go out as SSRC 0, which is the *sharer's*
    /// reserved voice SSRC, and the sharer's own anti-spoof gate
    /// (`audioRelayDecision`) drops it. So audio is withheld until an SSRC
    /// exists, and `withheldPacketCount` says how much — a number a host can
    /// show rather than a silence nobody can explain.
    ///
    /// A **sharer** sets `VoiceUplink.sharerSSRC` once, at construction time.
    ///
    /// Changing it rebuilds the packetizer, restarting sequence numbers and
    /// timestamps. That is correct: a different SSRC *is* a different stream,
    /// and continuing the old numbering would hand the receiver a stream that
    /// appears to have jumped in time.
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
