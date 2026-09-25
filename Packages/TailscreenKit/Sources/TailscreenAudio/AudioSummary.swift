// The voice receive path's `audio.summary` row, as a pure function on
// `VoiceStats` — the same extract-the-decision shape as the viewer's
// `ViewerSession.Diagnostics.transportSummaryFields`, and pinned the same
// way by `AudioSummaryTests` with no audio device behind it.

import Foundation
import TailscreenProtocol

extension VoiceStats {

    /// What was playing while the counters were measured.
    ///
    /// The counters alone cannot answer the question a crackle report asks.
    /// "Concealed 0, overran 0, underran 0" is equally true of a clean call
    /// and of a call whose distortion happened somewhere the voice path never
    /// looks — and on macOS one such place is the engine's own mixer, where a
    /// remote voice and the sharer's shared system audio are summed by
    /// `mainMixerNode` into one output with no headroom of ours. So the row
    /// carries what was feeding that mixer, which is the difference between
    /// "the voice path was fine and something downstream was not" and "there
    /// was nothing to hear".
    public struct PlaybackContext: Equatable, Sendable {
        /// Distinct remote voices being decoded — the number of live SSRC
        /// decoders. `VoiceMixer` sums the ones landing in the same 20 ms
        /// slot, so above 1 this is also the mixing depth.
        public var voiceStreams: Int
        /// Whether shared system audio is playing alongside those voices. A
        /// separate player node on macOS, summed with voice only at the
        /// engine's main mixer, so nothing in `VoiceStats` sees it.
        public var systemAudioPlaying: Bool
        /// Whether this host's own microphone is open. Not a receive-path
        /// counter either, but it is what engages voice processing (AEC),
        /// and enabling it restarts the engine.
        public var microphoneOn: Bool
        /// Current adaptive jitter target, in 20 ms buffers. The gauge the
        /// overrun and underrun counters are relative to: the same overrun
        /// count means something different at depth 3 and at depth 8.
        public var jitterTargetDepth: Int
        /// Effective output device, when the host knows it. Absent rather
        /// than a placeholder on a host that does not name its devices.
        public var outputDevice: String?
        /// Whether the playback queue's depth is accounted for by whoever
        /// built this context.
        ///
        /// `overrunDrops` and `underruns` are counted by the *host's* audio
        /// sink, not by the decode path, so a host that does not track its
        /// queue has no value for them — and a zero in that case would read
        /// as "nothing was dropped", which is the opposite of "nobody
        /// looked". False omits both fields instead, on the same principle
        /// as `transport.summary` leaving out `rr_age_ms` when no report has
        /// ever arrived.
        public var playbackQueueTracked: Bool

        public init(
            voiceStreams: Int = 0,
            systemAudioPlaying: Bool = false,
            microphoneOn: Bool = false,
            jitterTargetDepth: Int = 0,
            outputDevice: String? = nil,
            playbackQueueTracked: Bool = false
        ) {
            self.voiceStreams = voiceStreams
            self.systemAudioPlaying = systemAudioPlaying
            self.microphoneOn = microphoneOn
            self.jitterTargetDepth = jitterTargetDepth
            self.outputDevice = outputDevice
            self.playbackQueueTracked = playbackQueueTracked
        }
    }

    /// Whether a window is worth recording at all.
    ///
    /// True while audio is actually running — any voice decoding, system
    /// audio playing, or a live microphone. This is deliberately **not** the
    /// "only when a counter moved" guard that kept these numbers out of
    /// bundles in the first place: suppressing an unchanged window hides a
    /// steady-state fault, which is the whole failure being fixed, while
    /// suppressing a window with no audio in it hides nothing — the
    /// lifecycle events (`mic.attached`, `system_audio.started`,
    /// `voice.ssrc.assigned`) already say whether audio should have been
    /// running, so an absent row is unambiguous rather than silent.
    public static func shouldRecordSummary(context: PlaybackContext) -> Bool {
        context.voiceStreams > 0 || context.systemAudioPlaying || context.microphoneOn
    }

    /// The `audio.summary` fields for one window.
    ///
    /// Deltas for every counter and gauges as they stand now, exactly like
    /// the viewer's transport row: the question a summary answers is "what
    /// happened in these five seconds", and a running total makes a reader
    /// subtract two rows to find out.
    ///
    /// `clamped` is the one to read first on a distortion report. It counts
    /// decoded buffers holding a sample outside [-1, 1] — i.e. voice that was
    /// already hot before anything else was summed onto it — so a non-zero
    /// count with `voice_streams` above 1, or alongside `system_audio`, says
    /// the mix is clipping rather than the network dropping anything.
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
            "voice_streams": DiagnosticValue(context.voiceStreams),
            "system_audio": .bool(context.systemAudioPlaying),
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
