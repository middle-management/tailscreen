import Foundation
import TailscreenProtocol

/// The sharer's end of the voice call: speak to every viewer, and hear them.
/// A pairing — `VoiceUplink` at the reserved sharer SSRC plus a
/// `VoiceDownlink` for viewers' relayed voices — so the two hosts that need
/// it agree on the SSRC, muted-start, and device-release-on-stop details.
///
/// Not symmetric with the viewer, whose downlink lives inside
/// `ViewerSession`: a sharer's inbound audio arrives through the server's
/// `onAudioReceived` after its anti-spoof gate has vetted the sender's SSRC.
///
/// `@unchecked Sendable`: `receive` runs on the server's receive thread while
/// `stop()` runs on whatever thread tore the share down, and neither halt can
/// detach `onAudioReceived` first to drain it. Both halves own their own lock.
public final class SharerVoice: @unchecked Sendable {
    private let uplink: VoiceUplink
    private let downlink = VoiceDownlink()

    /// The viewers' decoded voices, already summed into one frame per 20 ms
    /// playout slot (`VoiceDownlink.onMixedPCM`). The host queues each frame
    /// onto its one output device as is: two viewers talking at once arrive
    /// as one mixed frame, not as alternating frames a queue would play in
    /// turn.
    public var onRemotePCM: (([Float]) -> Void)? {
        get { downlink.onMixedPCM }
        set { downlink.onMixedPCM = newValue }
    }

    /// The capture device stopped. Nil means the caller asked; an error means
    /// it went away, and the host should stop offering the mic control.
    public var onStopped: ((Error?) -> Void)? {
        get { uplink.onStopped }
        set { uplink.onStopped = newValue }
    }

    /// - Parameters:
    ///   - send: hand each packet to `TailscaleScreenShareServer.sendAudioRTP`,
    ///     which fans it out over the per-viewer audio send chains.
    public init(
        microphone: MicrophoneCapturing,
        encoder: OpusVoiceEncoder,
        send: @escaping (Data) -> Void
    ) {
        uplink = VoiceUplink(microphone: microphone, encoder: encoder, send: send)
        // Fixed here, not by a host: viewers' Opus decoders key on the protocol's reserved sharer SSRC.
        uplink.setSSRC(VoiceUplink.sharerSSRC)
        // Starting a share must not put somebody on the air.
        uplink.isMuted = true
    }

    /// Whether the sharer's voice reaches viewers. Drops at the source; see
    /// `MicrophonePipeline.isMuted`.
    public var isMuted: Bool {
        get { uplink.isMuted }
        set { uplink.isMuted = newValue }
    }

    /// Open the microphone. Throws what the backend throws — a host should
    /// treat that as "no microphone" and withhold the control rather than
    /// showing one that cannot unmute.
    public func start() throws {
        try uplink.start()
    }

    /// Release the device and forget every viewer's decoder. Called on share
    /// teardown, not left to `deinit` — an open device after Stop Sharing
    /// keeps the OS mic indicator lit. Safe while inbound audio is still
    /// arriving: `VoiceUplink.stop` waits for an in-flight delivery and
    /// `VoiceDownlink.reset` takes its own lock.
    public func stop() {
        uplink.stop()
        downlink.reset()
    }

    /// Feed one inbound audio datagram, straight from the server's
    /// `onAudioReceived`. Non-audio or malformed bytes decode to nil and are
    /// dropped.
    ///
    /// - Parameter nowNs: optional monotonic clock for the downlink's
    ///   loss-resilience decisions. Hosts that pass nothing get the uptime clock.
    public func receive(_ packet: Data, nowNs: UInt64? = nil) {
        downlink.ingest(packet, nowNs: nowNs)
    }

    /// Live viewer voices. Test visibility for the bound, same as the
    /// downlink's own.
    public var voiceCount: Int { downlink.voiceCount }
}
