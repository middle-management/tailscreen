import Foundation

/// A capture device that hands over PCM by blocking until it has some.
///
/// Both shipped backends are shaped this way — `ALSA.PCMRecorder.read(frames:)`
/// and `WASAPI.Recorder.read()` — and so is every other capture API worth
/// wrapping, because the alternative is a callback on a thread the platform
/// owns and will not tell you about. Naming the shape means the thread that
/// pumps it is written once, here, rather than once per platform with a
/// slightly different idea of what "stop" means.
///
/// Implementations are driven from exactly one thread and need no locking of
/// their own; `ThreadedMicrophone` guarantees that.
public protocol BlockingPCMSource: AnyObject {
    /// The device's negotiated format, as `readPCM` is currently delivering it.
    ///
    /// Read after every buffer rather than cached, because a device can be
    /// reconfigured underneath a running stream — the same reason
    /// `MicrophoneCapturing.onPCM` carries its format.
    ///
    /// **Describes the buffer, not the hardware.** A source that folds to mono
    /// itself reports `channelCount: 1`; see `MicrophoneCapturing.onPCM` for
    /// what forwarding the device's own channel count costs.
    var inputFormat: AudioInputFormat { get }

    /// Block until the device has audio, then return it interleaved at
    /// `inputFormat`. An empty result is legal (a timeout, a dropped period)
    /// and is not an error.
    ///
    /// **Blocking is the source's job, not the pump's.** WASAPI's read returns
    /// immediately and is frequently empty; an adapter over it must sleep out a
    /// fraction of a device period rather than hand back nothing in a tight
    /// loop, or the pump spins a core. Naming the requirement here is what
    /// keeps that decision in the one file that knows the device's cadence.
    func readPCM() throws -> CapturedPCM

    /// Release the device. Must unblock a `readPCM` in flight — by closing the
    /// handle, dropping the stream, whatever the platform's escape hatch is.
    /// Called exactly once, and possibly while `readPCM` is blocked.
    func closePCM()
}

/// One buffer from a capture device, and whether the stream has a hole
/// immediately before it.
public struct CapturedPCM: Sendable {
    /// Interleaved Float32 at the source's `inputFormat`.
    public let samples: [Float]

    /// The device dropped audio just before these samples — a WASAPI glitch
    /// flag, an ALSA overrun.
    ///
    /// Carried rather than swallowed because the consumer holds state *across*
    /// buffers: `CapturePCMConverter` keeps the previous buffer's last sample
    /// as the left neighbour of the next interpolation. Interpolating across a
    /// cut smears one artefact over both sides of a discontinuity that was
    /// already going to be audible. Whoever holds the state resets it — which
    /// is why this reaches `MicrophonePipeline.noteDiscontinuity()` rather than
    /// being logged and dropped.
    public let discontinuity: Bool

    public init(samples: [Float], discontinuity: Bool = false) {
        self.samples = samples
        self.discontinuity = discontinuity
    }
}

/// A microphone that can report device glitches.
///
/// A separate protocol rather than a field on `MicrophoneCapturing`, so a host
/// backend that has no glitch signal (or has not got round to plumbing one)
/// conforms to the seam unchanged. `VoiceUplink` asks for this conformance and
/// wires it when present.
public protocol DiscontinuityReporting: AnyObject {
    var onDiscontinuity: (() -> Void)? { get set }
}

/// Drives a `BlockingPCMSource` on its own thread and publishes the result
/// through the portable `MicrophoneCapturing` seam.
///
/// The mirror of `ThreadedAudioSink`, and mandatory for the same reason: the
/// read blocks, and both GUI hosts service their transport from the UI thread.
/// A microphone read on that thread is a frozen window between periods.
///
/// **Nothing is delivered after `stop()` returns.** That is the one guarantee
/// worth stating, because the obvious implementation — check a flag, then call
/// the callback — leaves a window where a buffer captured before the stop
/// arrives after it, and a host that tore its encoder down in between crashes
/// on a thread it does not know exists. The flag is therefore read *and* the
/// callback invoked under one lock, so `stop()` either precedes a delivery
/// entirely or waits for it.
public final class ThreadedMicrophone: MicrophoneCapturing, DiscontinuityReporting,
    @unchecked Sendable
{
    public var onPCM: (([Float], AudioInputFormat) -> Void)?
    public var onStopped: ((Error?) -> Void)?
    public var onDiscontinuity: (() -> Void)?

    private let source: BlockingPCMSource
    private let threadName: String
    /// Guards `running` *and* the callback invocations, which is the point —
    /// see the type's note on why checking the flag separately is not enough.
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public init(source: BlockingPCMSource, threadName: String = "tailscreen.microphone") {
        self.source = source
        self.threadName = threadName
    }

    /// Begin capturing. A second call while already running is a no-op — the
    /// same shape as `stop`, so a host that resends its state does not end up
    /// with two threads reading one device.
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

    /// Stop capturing and release the device.
    ///
    /// Idempotent. It does not join the capture thread — it does not need to,
    /// because the lock discipline above already means no callback can be
    /// *delivered* after this returns, which is the property a caller actually
    /// depends on. Joining would additionally park the caller for however long
    /// the source's blocking read takes to notice the close.
    ///
    /// It *can* block for the length of a delivery already in flight, since
    /// that delivery holds the lock. That is the guarantee, not a wart — but it
    /// is why `MicrophoneCapturing.onPCM` is documented as arithmetic only, and
    /// why the one rule for a host is that `onPCM` must not call back in here.
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
                // A read that failed *because we closed the device* is not a
                // device failure — it is the stop we asked for, and reporting
                // it as an error would put "your microphone disconnected" in
                // front of somebody who just clicked mute.
                let stillRunning = lock.withLock { running }
                deliverStopped(stillRunning ? error : nil)
                return
            }
            // Reported even for an empty buffer: the hole is in the stream, not
            // in these samples, and a glitch that arrives with nothing attached
            // still means the carried interpolation neighbour is stale.
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

    /// Fire `onStopped` exactly once, after the pump has given up.
    ///
    /// The callback is *fetched* under the lock and invoked outside it. Holding
    /// the lock across it would deadlock the obvious host reaction to "the
    /// microphone went away", which is to tear the capture down — and `stop()`
    /// takes this same lock. `onPCM` is different: it is delivered under the
    /// lock deliberately (see the type's note), which is why the one rule for
    /// a host is that `onPCM` must not call back into the microphone.
    private func deliverStopped(_ error: Error?) {
        let callback = lock.withLock { () -> ((Error?) -> Void)? in
            running = false
            return onStopped
        }
        callback?(error)
    }
}
