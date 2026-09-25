import Foundation

/// Wraps any `AudioSink` and runs its (blocking) `play(_:)` on a dedicated
/// thread, so the caller never blocks.
///
/// `ViewerSession.handleAudio` calls `audioSink.play(pcm)` **inline** on the
/// transport loop. Both the GTK and WinUI viewers service the transport from
/// the **UI thread** (swift-cross-ui ticks `RunLoop.main`), so a blocking
/// device write there (~50×/s) would stall the UI and freeze video. This
/// wrapper turns `play` into a non-blocking enqueue, doing the real write on
/// its own thread.
///
/// The wrapped sink's `play` is only ever invoked from the single drain
/// thread, so a backend whose device handle isn't thread-safe (`ALSA.PCMPlayer`,
/// a WASAPI `IAudioRenderClient`) needs no lock of its own. The bounded queue
/// drops the OLDEST buffer under sustained backpressure — audio is
/// best-effort, and dropping oldest keeps playback near the live edge.
public final class ThreadedAudioSink: AudioSink, @unchecked Sendable {
    private let wrapped: AudioSink
    private let maxQueued: Int
    private let cond = NSCondition()
    private var queue: [[Float]] = []
    private var stopped = false
    private var thread: Thread?

    /// - Parameters:
    ///   - sink: the real sink whose `play` blocks (e.g. `ALSAAudioSink`,
    ///     `WASAPIAudioSink`).
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
            wrapped.play(buffer)  // blocking device write — off the caller's thread
        }
    }
}
