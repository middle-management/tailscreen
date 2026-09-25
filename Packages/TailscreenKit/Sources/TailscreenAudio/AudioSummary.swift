// The voice receive path's `audio.summary` row, as a pure function on
// `VoiceStats` — the same extract-the-decision shape as the viewer's
// `ViewerSession.Diagnostics.transportSummaryFields`, and pinned the same
// way by `AudioSummaryTests` with no audio device behind it.

import Foundation
import TailscreenProtocol

extension VoiceStats {

    /// What was playing while the counters were measured. Clean counters are
    /// equally true of a good call and one whose distortion happened
    /// downstream (e.g. macOS's `mainMixerNode` summing voice with system
    /// audio with no headroom of ours), so this row carries what fed that mixer.
    public struct PlaybackContext: Equatable, Sendable {
        /// Distinct remote voices being decoded (live SSRC decoders).
        /// `VoiceMixer` sums same-slot ones, so above 1 this is mixing depth.
        public var voiceStreams: Int
        /// Whether shared system audio is being RECEIVED and played here — a
        /// separate player node on macOS, only summed with voice at the main
        /// mixer.
        ///
        /// Receive-side only, and named for it. The first cut called this
        /// `system_audio` and set it from inbound PT 99 alone, which a sharer
        /// never receives — so the machine that had just turned system audio
        /// ON reported `false` for every row while the viewer opposite it
        /// reported `true`, and a reader asking "was system audio in this
        /// call" got opposite answers from the two halves of one pair.
        public var systemAudioIn: Bool
        /// Whether this host is CAPTURING and sending system audio.
        ///
        /// The sharer's half of the same question, and not something the
        /// voice path can observe: system audio leaves through the capture
        /// helper, never through anything that reaches here. The host pushes
        /// it, exactly as it pushes `outputDevice`.
        public var systemAudioOut: Bool
        /// Whether this host's own microphone is open — engages AEC and restarts the engine.
        public var microphoneOn: Bool
        /// Current adaptive jitter target, in 20 ms buffers — the same
        /// overrun count means something different at depth 3 vs. 8.
        public var jitterTargetDepth: Int
        /// Deepest the playback queue would have had to be to keep every
        /// frame delivered in this window — see
        /// `VoiceReceiveDecisions.PlayoutBacklog`. Read it beside
        /// `jitterTargetDepth`: the two far apart is the shape that produces
        /// overruns and underruns at the same time, and is precisely what
        /// smoothed jitter alone could never show.
        public var burstDepth: Int
        /// Effective output device, when known. Absent rather than a placeholder.
        public var outputDevice: String?
        /// Whether the playback queue's depth is tracked by whoever built
        /// this context. `overrunDrops`/`underruns` come from the host's
        /// audio sink; false omits both fields rather than reading a
        /// no-tracking zero as "nothing was dropped".
        public var playbackQueueTracked: Bool

        public init(
            voiceStreams: Int = 0,
            systemAudioIn: Bool = false,
            systemAudioOut: Bool = false,
            microphoneOn: Bool = false,
            jitterTargetDepth: Int = 0,
            burstDepth: Int = 0,
            outputDevice: String? = nil,
            playbackQueueTracked: Bool = false
        ) {
            self.voiceStreams = voiceStreams
            self.systemAudioIn = systemAudioIn
            self.systemAudioOut = systemAudioOut
            self.microphoneOn = microphoneOn
            self.jitterTargetDepth = jitterTargetDepth
            self.burstDepth = burstDepth
            self.outputDevice = outputDevice
            self.playbackQueueTracked = playbackQueueTracked
        }
    }

    /// Whether a window is worth recording — true while audio is actually
    /// running. Deliberately not an "only when a counter moved" guard, which
    /// would hide the steady-state faults this exists to catch.
    public static func shouldRecordSummary(context: PlaybackContext) -> Bool {
        context.voiceStreams > 0 || context.systemAudioIn || context.systemAudioOut
            || context.microphoneOn
    }

    /// The `audio.summary` fields for one window: deltas for every counter,
    /// gauges as they stand now — like the viewer's transport row.
    ///
    /// `clamped` counts decoded buffers with a sample outside [-1, 1] — voice
    /// already hot before summing — so non-zero alongside `voice_streams` > 1
    /// or `system_audio_in` says the mix is clipping, not the network dropping.
    public func audioSummaryFields(
        since previous: VoiceStats, windowNs: UInt64, context: PlaybackContext
    ) -> [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = [
            "window_ms": DiagnosticValue(windowNs / 1_000_000),
            "concealed": DiagnosticValue(concealedFrames - previous.concealedFrames),
            "discontinuities": DiagnosticValue(discontinuities - previous.discontinuities),
            "clamped": DiagnosticValue(clampedBuffers - previous.clampedBuffers),
            "sys_clamped": DiagnosticValue(
                systemAudioClampedBuffers - previous.systemAudioClampedBuffers),
            "jitter_ms": .double((smoothedJitterMs * 10).rounded() / 10),
            "jitter_target": DiagnosticValue(context.jitterTargetDepth),
            "burst_depth": DiagnosticValue(context.burstDepth),
            "voice_streams": DiagnosticValue(context.voiceStreams),
            "system_audio_in": .bool(context.systemAudioIn),
            "system_audio_out": .bool(context.systemAudioOut),
            "mic_on": .bool(context.microphoneOn)
        ]
        if context.playbackQueueTracked {
            fields["overruns"] = DiagnosticValue(overrunDrops - previous.overrunDrops)
            fields["underruns"] = DiagnosticValue(underruns - previous.underruns)
        }
        if let device = context.outputDevice {
            fields["output_device"] = .string(device)
        }
        return fields
    }
}
