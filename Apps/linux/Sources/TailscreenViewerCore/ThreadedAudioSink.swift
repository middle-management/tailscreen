import ALSAKit
import Foundation
import TailscreenViewer

/// Wraps any `AudioSink` and runs its (blocking) `play(_:)` on a dedicated
/// thread, so the caller never blocks.
///
/// `ViewerSession.handleAudio` calls `audioSink.play(pcm)` **inline** on the
/// transport loop. In the SDL CLI that loop is separate from rendering, so a
/// blocking ALSA write there is tolerable. In the GTK viewer the transport
/// runs on the **GTK main thread** (swift-cross-ui ticks `RunLoop.main`, and
/// the transport `Task` is serviced by it), so a blocking ALSA write — up to
/// ALSA's ~50 ms buffer per call, ~50×/s — would stall the GTK main loop and
/// freeze video. This wrapper turns `play` into a non-blocking enqueue and does
/// the real write on its own thread.
///
/// The wrapped sink's `play` is only ever invoked from the single drain thread,
/// so an `ALSA.PCMPlayer` (whose PCM handle is not thread-safe) stays
/// single-threaded. A bounded queue drops the OLDEST buffer under sustained
/// backpressure (a wedged/slow device) — audio is best-effort and must never
/// grow memory without bound or add latency indefinitely; dropping oldest keeps
/// playback near the live edge.
public final class ThreadedAudioSink: AudioSink, @unchecked Sendable {
    private let wrapped: AudioSink
    private let maxQueued: Int
    private let cond = NSCondition()
    private var queue: [[Float]] = []
    private var stopped = false
    private var thread: Thread?

    /// - Parameters:
    ///   - sink: the real sink whose `play` blocks (e.g. `ALSAAudioSink`).
    ///   - maxQueuedBuffers: backpressure cap. At one 20 ms Opus frame per
    ///     buffer, the default 16 is ~320 ms — generous slack for jitter while
    ///     bounding both memory and worst-case latency.
    public init(wrapping sink: AudioSink, maxQueuedBuffers: Int = 16) {
        self.wrapped = sink
        self.maxQueued = max(1, maxQueuedBuffers)
        let t = Thread { [weak self] in self?.drainLoop() }
        t.name = "tailscreen-audio"
        t.start()
        self.thread = t
    }

    /// Enqueue PCM for playback and return immediately. Never blocks; never
    /// touches the wrapped sink.
    public func play(_ pcm: [Float]) {
        guard !pcm.isEmpty else { return }
        cond.lock()
        if !stopped {
            if queue.count >= maxQueued { queue.removeFirst() }  // drop oldest
            queue.append(pcm)
            cond.signal()
        }
        cond.unlock()
    }

    /// Stop the drain thread. Idempotent. Queued-but-unplayed audio is dropped
    /// (a viewer teardown wants to stop, not flush trailing sound).
    public func stop() {
        cond.lock()
        stopped = true
        queue.removeAll()
        cond.signal()
        cond.unlock()
        thread = nil
    }

    private func drainLoop() {
        while true {
            cond.lock()
            while queue.isEmpty && !stopped { cond.wait() }
            if stopped && queue.isEmpty {
                cond.unlock()
                return
            }
            let buffer = queue.removeFirst()
            cond.unlock()
            wrapped.play(buffer)  // blocking ALSA write — off the caller's thread
        }
    }
}

/// Build the Linux viewer's default audio sink: an `ALSAAudioSink` fronted by a
/// `ThreadedAudioSink` so the blocking device write never runs on the caller's
/// thread. Keeps `ALSAKit` an internal detail of Core — callers only see
/// `AudioSink`.
///
/// - Throws: `ALSA.Error` if the PCM device can't be opened/configured. Callers
///   treat audio as best-effort and continue video-only on failure.
public func makeThreadedALSAAudioSink(device: String = "default") throws -> AudioSink {
    let player = try ALSA.PCMPlayer(device: device)
    return ThreadedAudioSink(wrapping: ALSAAudioSink(player: player))
}
