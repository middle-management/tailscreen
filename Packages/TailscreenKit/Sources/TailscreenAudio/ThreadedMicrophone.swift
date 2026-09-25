import Foundation

/// A capture device that hands over PCM by blocking until it has some — the
/// shape a callback on a platform-owned thread cannot support, so the capture
/// thread is written once here rather than once per platform.
///
/// The two shipped backends don't both arrive this way: `ALSA.PCMRecorder`
/// genuinely blocks, while `WASAPI.Recorder.read()` returns immediately and
/// is frequently empty (its adapter sleeps out the difference; see `readPCM`).
///
/// Implementations are driven from exactly one thread and need no locking of
/// their own; `ThreadedMicrophone` guarantees that.
public protocol BlockingPCMSource: AnyObject {
    /// The device's negotiated format, as `readPCM` is currently delivering
    /// it. Read after every buffer, not cached — a device can be
    /// reconfigured mid-stream. Describes the buffer, not the hardware: a
    /// source that folds to mono reports `channelCount: 1`.
    var inputFormat: AudioInputFormat { get }

    /// Block until the device has audio, then return it interleaved at
    /// `inputFormat`. An empty result is legal (a timeout, a dropped period).
    /// Blocking is the source's job, not the pump's — an adapter over a
    /// non-blocking read must sleep out a fraction of a device period, or the pump spins a core.
    func readPCM() throws -> CapturedPCM

    /// Release the device. Must unblock a `readPCM` in flight. Called
    /// exactly once, possibly while `readPCM` is blocked.
    func closePCM()
}

/// One buffer from a capture device, and whether the stream has a hole
/// immediately before it.
public struct CapturedPCM: Sendable {
    /// Interleaved Float32 at the source's `inputFormat`.
    public let samples: [Float]

    /// The device dropped audio just before these samples (WASAPI glitch
    /// flag, ALSA overrun). Carried, not swallowed, because
    /// `CapturePCMConverter` keeps the previous buffer's last sample as an
    /// interpolation neighbour, and interpolating across a cut smears the
    /// artefact — hence this reaches `MicrophonePipeline.noteDiscontinuity()`.
    public let discontinuity: Bool

    public init(samples: [Float], discontinuity: Bool = false) {
        self.samples = samples
        self.discontinuity = discontinuity
    }
}

/// A microphone that can report device glitches. A separate protocol, not a
/// field on `MicrophoneCapturing`, so a backend with no glitch signal
/// conforms unchanged. `VoiceUplink` wires it in when present.
public protocol DiscontinuityReporting: AnyObject {
    var onDiscontinuity: (() -> Void)? { get set }
}

/// Drives a `BlockingPCMSource` on its own thread and publishes the result
/// through the portable `MicrophoneCapturing` seam. The mirror of
/// `ThreadedAudioSink`: the read blocks, and both GUI hosts service transport
/// from the UI thread, where a microphone read would freeze it.
///
/// **Nothing is delivered after `stop()` returns.** The flag is read and the
/// callback invoked under one lock, so `stop()` either precedes a delivery
/// entirely or waits for it — the naive check-then-call leaves a window
/// where a buffer arrives after a host has torn its encoder down.
public final class ThreadedMicrophone: MicrophoneCapturing, @unchecked Sendable {
    public var onPCM: (([Float], AudioInputFormat) -> Void)?
    public var onStopped: ((Error?) -> Void)?
    public var onDiscontinuity: (() -> Void)?

    private let source: BlockingPCMSource
    private let threadName: String
    /// Guards `running` and the callback invocations together — the point.
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public init(source: BlockingPCMSource, threadName: String = "tailscreen.microphone") {
        self.source = source
        self.threadName = threadName
    }

    /// Begin capturing. A second call while already running is a no-op, so a
    /// host that resends its state doesn't end up with two threads reading one device.
    public func start() throws {
        let shouldStart = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [weak self] in self?.pump() }
        thread.name = threadName
        // Audio capture is soft-real-time: a late buffer is a gap in somebody's
        // sentence. Above default, below the UI, matching ThreadedAudioSink.
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Stop capturing and release the device. Idempotent. Does not join the
    /// capture thread — the lock discipline already guarantees no callback
    /// delivers after this returns, without parking the caller for however
    /// long the close takes to be noticed. Can block for a delivery already
    /// in flight (it holds the lock) — which is why a host's `onPCM` must
    /// never call back into this.
    public func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            let was = running
            running = false
            return was
        }
        guard wasRunning else { return }
        // Outside the lock: closing may block briefly, and the pump thread
        // needs the lock to notice it has been stopped.
        source.closePCM()
        thread = nil
    }

    /// The capture loop. Runs on its own thread until stopped or the device
    /// fails.
    private func pump() {
        while true {
            let captured: CapturedPCM
            do {
                captured = try source.readPCM()
            } catch {
                // A read failing because we closed the device is the stop we
                // asked for, not a failure — don't report "disconnected" for a mute click.
                let stillRunning = lock.withLock { running }
                deliverStopped(stillRunning ? error : nil)
                return
            }
            // Reported even for an empty buffer: the hole is in the stream, not these samples.
            if captured.discontinuity {
                let report = lock.withLock { running ? onDiscontinuity : nil }
                report?()
            }
            guard !captured.samples.isEmpty else {
                // A timeout or a dropped period. Still a chance to notice a
                // stop, so loop rather than spin on a dead flag.
                if !lock.withLock({ running }) {
                    deliverStopped(nil)
                    return
                }
                continue
            }
            let format = source.inputFormat
            let samples = captured.samples
            let delivered = lock.withLock { () -> Bool in
                guard running else { return false }
                onPCM?(samples, format)
                return true
            }
            if !delivered {
                deliverStopped(nil)
                return
            }
        }
    }

    /// Fire `onStopped` exactly once, after the pump has given up. Fetched
    /// under the lock, invoked outside it — holding the lock across it would
    /// deadlock a host reaction that calls `stop()`, which takes this same lock.
    private func deliverStopped(_ error: Error?) {
        let callback = lock.withLock { () -> ((Error?) -> Void)? in
            running = false
            return onStopped
        }
        callback?(error)
    }
}

// In an extension so the class line stays single-line (wrapped with three conformances, which lint rejects).
extension ThreadedMicrophone: DiscontinuityReporting {}
