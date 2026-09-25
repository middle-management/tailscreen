import Foundation

/// Accumulates PCM and hands it out in exact 960-sample (20 ms) frames.
///
/// Opus encodes fixed frame sizes, and no capture backend delivers them: ALSA
/// hands over a period, WASAPI whatever the device had ready. Everything in
/// between is a remainder that must be carried, not dropped — dropping it is
/// inaudible per buffer and a rising pitch over a call.
public struct PCMFramer {
    public let frameSamples: Int
    private var carry: [Float] = []

    public init(frameSamples: Int = 960) {
        self.frameSamples = frameSamples
    }

    /// Append `pcm` and return every whole frame now available.
    public mutating func push(_ pcm: [Float]) -> [[Float]] {
        guard frameSamples > 0 else { return [] }
        carry.append(contentsOf: pcm)
        guard carry.count >= frameSamples else { return [] }
        var frames: [[Float]] = []
        var offset = 0
        while carry.count - offset >= frameSamples {
            frames.append(Array(carry[offset..<(offset + frameSamples)]))
            offset += frameSamples
        }
        carry.removeFirst(offset)
        return frames
    }

    /// Drop the partial frame — carrying it across a session/device change
    /// splices two unrelated moments together.
    public mutating func reset() {
        carry.removeAll(keepingCapacity: true)
    }

    /// Samples held back awaiting a full frame. Exposed for tests, which is
    /// the only way to see that the remainder is carried rather than dropped.
    public var pendingSamples: Int { carry.count }
}

/// Everything between a `MicrophoneCapturing` backend and an encoded Opus
/// packet: downmix, resample, frame, encode — and the mute latch. Each step
/// fails quietly if wrong: a bad resample ratio chipmunks, a dropped
/// remainder climbs pitch, a leaking mute is a privacy failure.
///
/// **Not** thread-safe: driven from the backend's serial capture thread.
/// `isMuted` is the exception (set from the UI), which is why the mute
/// decision happens at the top of `ingest`, not after encoding.
public final class MicrophonePipeline: @unchecked Sendable {
    private let converter = CapturePCMConverter()
    private var framer: PCMFramer
    private let encoder: OpusVoiceEncoder
    private let lock = NSLock()
    private var muted = false

    /// One encoded Opus packet, ready to packetize as RTP PT 98.
    public var onAccessUnit: ((Data) -> Void)?
    /// An encode failed. Surfaced rather than swallowed so a host can stop
    /// claiming the microphone works; the pipeline itself keeps going, since
    /// one bad frame is not a reason to end a call.
    public var onEncodeError: ((Error) -> Void)?

    public init(encoder: OpusVoiceEncoder, frameSamples: Int = OpusVoiceEncoder.frameSamples) {
        self.encoder = encoder
        self.framer = PCMFramer(frameSamples: frameSamples)
    }

    /// Muting stops audio leaving this machine — drops at the source rather
    /// than encoding silence, so a leak bug can't hide as working software.
    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set {
            lock.withLock { muted = newValue }
            if newValue {
                // Drop the partial frame too, so unmuting cannot emit audio
                // recorded while muted as the head of the first live frame.
                lock.withLock { framer.reset() }
            }
        }
    }

    /// Feed one buffer from the backend. Emits zero or more access units.
    public func ingest(_ interleaved: [Float], format: AudioInputFormat) {
        guard !isMuted else { return }
        let mono = converter.convert(interleaved, from: format)
        guard !mono.isEmpty else { return }
        let frames = lock.withLock { framer.push(mono) }
        for frame in frames {
            do {
                if let au = try encoder.encode(pcm: frame) { onAccessUnit?(au) }
            } catch {
                onEncodeError?(error)
            }
        }
    }

    /// Drop all carried state — a new session, or a device change.
    public func reset() {
        converter.reset()
        lock.withLock { framer.reset() }
    }

    /// The device dropped audio just before the next buffer. Resets the
    /// converter, not the framer: the converter's carried sample now sits
    /// across a hole and would smear an artefact; the framer's carry is real
    /// audio that dropping would turn into a second, self-inflicted gap.
    public func noteDiscontinuity() {
        converter.reset()
    }
}
