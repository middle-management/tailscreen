import Foundation
import TailscreenProtocol

/// The sharer's end of the voice call: speak to every viewer, and hear them.
///
/// A pairing, not new machinery — `VoiceUplink` at the reserved sharer SSRC
/// plus a `VoiceDownlink` for the viewers' relayed voices. It exists as a named
/// type because the two hosts that need it would otherwise each assemble the
/// pair themselves, and the parts that must agree are exactly the parts that
/// are easy to get subtly different: which SSRC the sharer speaks under, that
/// the microphone starts muted, and that stopping a share releases the device
/// rather than leaving it open until the process exits.
///
/// The host supplies both platform ends — a `MicrophoneCapturing` backend, and
/// somewhere to play what arrives — so this stays portable and CI-testable.
///
/// Deliberately NOT symmetric with the viewer, which gets its downlink inside
/// `ViewerSession` (it already owns the RTP demux). A sharer's inbound audio
/// arrives through the server's `onAudioReceived` callback instead, after the
/// server's anti-spoof gate has vetted the sender's SSRC — so by the time a
/// packet reaches `receive` it is a packet from an admitted viewer speaking
/// under the SSRC that viewer was assigned.
///
/// `@unchecked Sendable`, and it has to be: `receive` runs on the server's
/// receive thread while `stop()` runs on whichever thread tore the share down,
/// and the server's callback contract ("assign before `start()`, leave alone
/// until after `stop()` returns") means no host can detach `onAudioReceived`
/// first to drain it. Both halves own their own lock — `VoiceUplink`'s, and
/// `VoiceDownlink`'s.
public final class SharerVoice: @unchecked Sendable {
    private let uplink: VoiceUplink
    private let downlink = VoiceDownlink()

    /// A viewer's decoded voice, tagged with their SSRC. The host mixes and
    /// plays it; the tag is kept because "who is talking" is information a
    /// sharer's UI can use and mixing destroys irreversibly.
    public var onRemotePCM: ((UInt32, [Float]) -> Void)? {
        get { downlink.onPCM }
        set { downlink.onPCM = newValue }
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
        // Fixed, and set here rather than by a host: a sharer speaks under the
        // protocol's reserved voice SSRC, and viewers' Opus decoders are keyed
        // on it. There is no correct second answer, so there is no parameter.
        uplink.setSSRC(VoiceUplink.sharerSSRC)
        // Starting a share must not put somebody on the air — the same rule the
        // viewer follows, and the same default as the macOS app.
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

    /// Release the device and forget every viewer's decoder.
    ///
    /// Called on share teardown, not left to `deinit`: an open capture device
    /// after Stop Sharing keeps the OS microphone indicator lit, which reads to
    /// everyone in the room as "still recording".
    ///
    /// Safe to call while inbound audio is still arriving — which it always
    /// is, since both hosts stop voice before the server. `VoiceUplink.stop`
    /// waits for an in-flight delivery and `VoiceDownlink.reset` takes the
    /// downlink's lock, so neither drops state through the middle of a packet.
    public func stop() {
        uplink.stop()
        downlink.reset()
    }

    /// Feed one inbound audio datagram, straight from the server's
    /// `onAudioReceived`. Non-audio or malformed bytes decode to nil and are
    /// dropped.
    ///
    /// - Parameter nowNs: optional monotonic clock for the downlink's
    ///   loss-resilience decisions (gap concealment, decoder cooldown, idle
    ///   eviction). Hosts that pass nothing — both shipped sharer hosts call
    ///   this straight off the receive thread — get the uptime clock.
    public func receive(_ packet: Data, nowNs: UInt64? = nil) {
        downlink.ingest(packet, nowNs: nowNs)
    }

    /// Live viewer voices. Test visibility for the bound, same as the
    /// downlink's own.
    public var voiceCount: Int { downlink.voiceCount }
}
