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

    /// Drop the partial frame. A new session or a device change — carrying
    /// audio across either splices two unrelated moments together.
    public mutating func reset() {
        carry.removeAll(keepingCapacity: true)
    }

    /// Samples held back awaiting a full frame. Exposed for tests, which is
    /// the only way to see that the remainder is carried rather than dropped.
    public var pendingSamples: Int { carry.count }
}

/// Everything between a `MicrophoneCapturing` backend and an encoded Opus
/// packet: downmix, resample, frame, encode — and the mute latch.
///
/// Host-agnostic and therefore testable, which matters because each of these
/// steps fails quietly. A wrong resample ratio is a chipmunk, a dropped
/// remainder is a slow pitch climb, and a mute that leaks is a privacy
/// failure nobody notices until it is too late.
///
/// **Not** thread-safe: it is driven from the backend's capture thread, which
/// is serial. `isMuted` is the exception — it is set from the UI — and is an
/// atomic-by-construction `Bool` read once per buffer. A torn read there costs
/// one 20 ms frame in the wrong direction, which is why the mute *decision*
/// also happens at the top of `ingest` rather than after encoding.
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

    /// Muting stops audio leaving this machine.
    ///
    /// It drops at the SOURCE rather than encoding silence: silence still costs
    /// bandwidth on every 20 ms frame, and — the part that matters — a bug that
    /// leaked audio while "muted" would be indistinguishable from working
    /// software until somebody heard something they should not have. Nothing
    /// downstream of this gate ever sees a muted sample.
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
}
