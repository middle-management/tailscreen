import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import os

class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    /// Separate output object for the `.audio` stream type, on its own serial
    /// queue. Kept distinct from `streamOutput` so the video output's
    /// queue-confined counters (`lastSampleNotifyNs`, etc.) are never touched
    /// from a second thread. Nil unless `capturesAudio` was set before start.
    private var audioStreamOutput: AudioStreamOutput?
    /// When set before `start(...)`, the SCStream is configured to also
    /// capture 48 kHz mono system audio (`excludesCurrentProcessAudio` on, so
    /// Tailscreen's own output — including played-back viewer voices — is
    /// never re-captured). Consumed in `startStream`; the capture-helper sets
    /// it from `PickerSelection.captureAudio`.
    var capturesAudio: Bool = false
    /// Forwards each audio `CMSampleBuffer` the SCStream delivers. Fires on the
    /// dedicated audio-output queue — the helper feeds it straight into a
    /// `SystemAudioTap` with no MainActor hop.
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Live SCStreamConfiguration so `updateConfiguration` can preserve
    /// frame-interval / pixel-format / queueDepth across resize-driven
    /// updates and only change width / height.
    private var streamConfig: SCStreamConfiguration?
    /// `pointPixelScale` from the original filter — kept so callers
    /// observing point-sized contentRect changes can multiply through to
    /// pixel dims without re-querying the filter.
    private(set) var pointPixelScale: Float = 1
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
    /// Fires whenever `SCStreamFrameInfo.contentRect` changes by ≥0.5 pt
    /// between consecutive frames. Source rect is in points (within the
    /// configured pixel buffer); multiply by `pointPixelScale` to get
    /// the captured-content size in pixels. Use this to drive
    /// `updateConfiguration` so the encoder buffer follows window
    /// resizes instead of staying pinned at the start-time dims.
    var onContentRectChanged: ((CGRect) -> Void)?
    /// Liveness signal: fires (throttled to ~1 Hz) whenever the SCStream
    /// delivers *any* sample to the delegate, including `.idle` frames on a
    /// static screen. Distinct from `onFrameCaptured`, which fires only for
    /// `.complete` frames carrying a pixel buffer (and so goes silent on a
    /// static screen). The capture helper forwards this as a heartbeat so the
    /// parent can tell a wedged SCStream from a screen that isn't changing.
    var onStreamSample: (() -> Void)?
    /// Fires when the SCStream terminates on its own — e.g. user clicked the
    /// menubar "Stop Screen Recording" item, or the stream hit an error.
    var onStreamStopped: ((Error?) -> Void)?

    /// Per-instance short tag for cross-referencing lifecycle log
    /// lines. Lets us tell apart concurrent attempts when investigating
    /// a "stuck capture" report.
    private let sessionID = String(format: "%04x", UInt16.random(in: 0...0xFFFF))
    /// Wall-clock anchor for "ms since instance created" log timing.
    private let createdAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds

    /// Time the most recent ScreenCapture instance finished
    /// `stopCapture`. Used by `start()` to log how long ago the prior
    /// session ended — short windows correlate with the "interrupted"
    /// / "noFramesDelivered" replayd cool-down failures.
    private static let lastStopAtNs = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    /// Timestamp (uptime ns) of the most recent observation that
    /// replayd's per-bundle slot was wedged — `noFramesDelivered`
    /// after `startCapture.completion.ok`, or a startCapture
    /// watchdog timeout. While inside the cool-down window after that
    /// timestamp, new sessions refuse early so the user gets a clear
    /// error instead of waiting through doomed retries. Outside the
    /// window, we let them try again because replayd sometimes
    /// recovers on its own.
    private static let bundlePoisonedAtNs = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private static let bundlePoisonCooldownNs: UInt64 = 30 * 1_000_000_000

    private func logEvent(_ phase: String, extra: String = "") {
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- createdAtNs) / 1_000_000
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("ScreenCapture[\(sessionID)] +\(elapsedMs)ms \(phase)\(suffix)")
    }

    override init() {
        super.init()
        let prevAgeMs: String
        if let last = Self.lastStopAtNs.withLock({ $0 }) {
            let ms = (DispatchTime.now().uptimeNanoseconds &- last) / 1_000_000
            prevAgeMs = "msSincePreviousStop=\(ms)"
        } else {
            prevAgeMs = "msSincePreviousStop=∅"
        }
        print("ScreenCapture[\(sessionID)] +0ms init \(prevAgeMs)")
    }

    /// Set while `start()` is awaiting `startCapture`. SCStream sometimes
    /// fires `didStopWithError` synchronously without ever resolving the
    /// startCapture completion handler, so we tee the delegate error into
    /// this box to fail fast instead of waiting for the watchdog.
    private let pendingStart = OSAllocatedUnfairLock<ContinuationBox?>(initialState: nil)

    /// Flips true the first time the stream output delivers a sample.
    /// `start()` waits for it after `startCapture` resumes; if no frame
    /// arrives within the watchdog window we throw a retriable error
    /// because replayd is awake but not pumping.
    private let firstFrameSeen = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Deep-link into System Settings → Privacy & Security → Screen
    /// Recording. First-run users frequently miss the macOS TCC prompt
    /// (or click "Don't Allow"); once denied, the prompt never re-fires
    /// and the only recovery is the settings pane. Surfaced from the
    /// startCapture-timeout alert so the user lands on the right toggle.
    @MainActor
    static func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pre-flight gate shared by every SCStream bring-up. Refuses
    /// early if a prior session poisoned replayd's per-bundle slot,
    /// and otherwise sleeps out the post-stop cool-down so the new
    /// SCStream doesn't get hit by replayd's "application connection
    /// being interrupted" race.
    private func applyStartCooldowns() async throws {
        // Refuse early if a prior SCStream poisoned the bundle's
        // replayd slot inside the cool-down window. After the window
        // we let the user try again — replayd sometimes recovers on
        // its own and we'd rather give them a chance than force a
        // restart unnecessarily.
        if let poisonedAt = Self.bundlePoisonedAtNs.withLock({ $0 }) {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- poisonedAt
            if elapsedNs < Self.bundlePoisonCooldownNs {
                let remainMs = (Self.bundlePoisonCooldownNs - elapsedNs) / 1_000_000
                logEvent("start.refused", extra: "bundleSlotPoisoned remaining=\(remainMs)ms")
                throw ScreenCaptureError.bundleSlotPoisoned
            }
            // Cool-down elapsed — clear the flag and let the attempt
            // proceed. If it fails again the flag will reset.
            Self.bundlePoisonedAtNs.withLock { $0 = nil }
            logEvent("start.poison.cleared", extra: "elapsed=\(elapsedNs / 1_000_000)ms")
        }
        // Replayd needs a brief cool-down between stop and the next
        // start on the same bundle. If we start within ~1 s of the
        // last stop, the new SCStream comes up and immediately fires
        // didStopWithError(-3805 "application connection being
        // interrupted"). Worse, that interrupt poisons the bundle's
        // slot — every subsequent startCapture acks but never
        // delivers a sample, until process exit. Waiting out the
        // cool-down here avoids the poison entirely.
        let cooldownMs: UInt64 = 2000
        if let lastStop = Self.lastStopAtNs.withLock({ $0 }) {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- lastStop
            let elapsedMs = elapsedNs / 1_000_000
            if elapsedMs < cooldownMs {
                let waitMs = cooldownMs - elapsedMs
                logEvent("start.cooldown.waiting", extra: "remaining=\(waitMs)ms sinceLastStop=\(elapsedMs)ms")
                try await Task.sleep(for: .milliseconds(Int(waitMs)))
            }
        }
    }

    /// Bring up an `SCStream` against an `SCContentFilter` chosen by
    /// the user via `SCContentSharingPicker` (display, single window,
    /// single application, or multi-app set). Width/height come from
    /// the filter's reported `contentRect` × `pointPixelScale` so all
    /// modes work uniformly without an external resolution hint. Must
    /// only be called from inside the capture-helper subprocess —
    /// deserializing an `SCContentFilter` in the main process would
    /// register the parent with replayd and break the helper child's
    /// stream (CLAUDE.md).
    /// Round a pixel dimension down to an even number ≥ 2. H.264 and HEVC
    /// 4:2:0 require even width and height; an odd dimension (single-window or
    /// single-app shares, fractional-scale Retina modes) can encode fine on the
    /// sharer's VideoToolbox yet show a garbage edge column or a 1px chroma
    /// shift on a *different* decoder — a classic works-on-my-Mac cross-device
    /// bug. Rounding *down* guarantees we never encode past the captured region.
    private static func evenFloor(_ value: Int) -> Int {
        max(2, value & ~1)
    }

    /// `fps` caps the SCStream's delivery rate via `minimumFrameInterval`
    /// — the capture-helper threads the user's quality setting through
    /// here so the stream and the encoder agree on the frame rate.
    /// `colorInfo` selects the capture pixel format (8- vs 10-bit) and the
    /// requested `colorSpaceName` (Display P3 / BT.2020 for wide-gamut / HDR
    /// displays); the shipped BT.709 8-bit default leaves both untouched.
    func start(filter: SCContentFilter, fps: Int = 60, colorInfo: ColorInfo = .bt709FullRange8) async throws {
        try await applyStartCooldowns()
        // Pull resolution from the filter directly. `contentRect` is in
        // points (CG-coordinate space), so we multiply by the filter's
        // own `pointPixelScale` to land on pixel dimensions that match
        // the encoder's expectations across display/window/app modes.
        let rect = filter.contentRect
        let scale = filter.pointPixelScale
        self.pointPixelScale = scale
        let pxWidth = max(2, Int((rect.width * CGFloat(scale)).rounded()))
        let pxHeight = max(2, Int((rect.height * CGFloat(scale)).rounded()))
        try await startStream(
            filter: filter,
            pixelSize: CGSize(width: pxWidth, height: pxHeight),
            fps: fps,
            colorInfo: colorInfo,
            sourceTag: "filter rect=\(Int(rect.width))x\(Int(rect.height))pt scale=\(scale)"
        )
    }

    /// Push new output buffer dimensions to the running SCStream so the
    /// captured content fills the buffer instead of leaving black margins
    /// when the shared window resizes. Preserves every other property of
    /// the live configuration (frame interval, pixel format, queueDepth).
    /// Sized in pixels — callers multiply contentRect's point dims by
    /// `pointPixelScale` before passing in.
    ///
    /// Apple's `updateConfiguration` is documented since macOS 12.3 and
    /// is the supported path for "follow the shared window as it grows
    /// or shrinks"; tearing the SCStream down + restarting would force a
    /// replayd cool-down + a fresh permission/bundle slot dance.
    func updateConfiguration(pixelWidth: Int, pixelHeight: Int) async {
        guard let stream, let baseConfig = streamConfig else {
            logEvent(
                "updateConfiguration.skip",
                extra: "stream=nil-or-no-baseConfig px=\(pixelWidth)x\(pixelHeight)")
            return
        }
        let w = Self.evenFloor(pixelWidth)
        let h = Self.evenFloor(pixelHeight)
        if baseConfig.width == w && baseConfig.height == h {
            // Nothing to do — already at the requested size.
            return
        }
        let prev = "\(baseConfig.width)x\(baseConfig.height)"
        baseConfig.width = w
        baseConfig.height = h
        logEvent("updateConfiguration.apply", extra: "px=\(prev) -> \(w)x\(h)")
        do {
            try await stream.updateConfiguration(baseConfig)
            logEvent("updateConfiguration.ok", extra: "px=\(w)x\(h)")
        } catch {
            logEvent("updateConfiguration.fail", extra: "err=\(error) px=\(w)x\(h)")
        }
    }

    /// Live-retune the capture frame rate (fps ladder) by rewriting the base
    /// configuration's `minimumFrameInterval` and pushing it through
    /// `stream.updateConfiguration` — the same supported live-reconfig path
    /// `updateConfiguration(pixelWidth:pixelHeight:)` uses, so it never tears
    /// the SCStream down. No-op if the stream isn't up or fps is unchanged.
    func updateFrameInterval(fps: Int) async {
        guard let stream, let baseConfig = streamConfig else {
            logEvent("updateFrameInterval.skip", extra: "stream=nil-or-no-baseConfig fps=\(fps)")
            return
        }
        let interval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        if CMTimeCompare(baseConfig.minimumFrameInterval, interval) == 0 { return }
        baseConfig.minimumFrameInterval = interval
        logEvent("updateFrameInterval.apply", extra: "fps=\(fps)")
        do {
            try await stream.updateConfiguration(baseConfig)
            logEvent("updateFrameInterval.ok", extra: "fps=\(fps)")
        } catch {
            logEvent("updateFrameInterval.fail", extra: "err=\(error) fps=\(fps)")
        }
    }

    /// Shared SCStream bring-up. `filter` is passed in from
    /// `start(filter:)` (the picker subprocess produces it). The rest
    /// of the lifecycle — addStreamOutput, startCapture watchdog,
    /// first-frame wait — runs uniformly here.
    private func startStream(
        filter: SCContentFilter,
        pixelSize: CGSize,
        fps: Int,
        colorInfo: ColorInfo,
        sourceTag: String
    ) async throws {
        let config = SCStreamConfiguration()
        config.width = Self.evenFloor(Int(pixelSize.width))
        config.height = Self.evenFloor(Int(pixelSize.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        // Full-range biplanar 4:2:0 — matches what VideoToolbox wants
        // natively, so the encoder skips an internal BGRA→YUV conversion
        // (cheaper, and removes a 601/709 ambiguity that was crushing
        // near-black UI surfaces under the limited-range default). The encoder
        // tags the bitstream full-range so the decoder reads the right range
        // from the VUI. `ColorInfo` picks 8-bit (`420f`, shipped default) vs
        // 10-bit (`x420`) for deep-color / HDR sources.
        config.pixelFormat = colorInfo.capturePixelFormat
        // Request the source's color space only for non-709 gamuts (Display
        // P3 / BT.2020); BT.709 leaves SCStream at its default so the shipped
        // capture path is untouched. SCStream converts captured content into
        // this space; the encoder's matching VUI tags carry it to viewers.
        if let colorSpaceName = colorInfo.captureColorSpaceName {
            config.colorSpaceName = colorSpaceName
        }
        config.showsCursor = true
        config.queueDepth = 5
        if capturesAudio {
            // Match the voice codec format so the helper's OpusVoiceEncoder
            // and the viewer's OpusVoiceDecoder (both hardwired mono 48 kHz)
            // round-trip unchanged. `excludesCurrentProcessAudio` drops
            // Tailscreen's own output — i.e. viewer voices `MicCapture`
            // plays — from the mix, so viewer speech is never re-broadcast as
            // system audio (no loop).
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            config.excludesCurrentProcessAudio = true
        }
        self.streamConfig = config
        let fmt = colorInfo.bitDepth >= 10 ? "x420" : "420f"
        logEvent(
            "start.config",
            extra: "\(sourceTag) size=\(config.width)x\(config.height) fps=\(fps) pixelFormat=\(fmt)")

        // Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Create and add output. Tee first-frame arrival through
        // firstFrameSeen so start() can wait for it after startCapture
        // resumes — replayd sometimes ack's startup but never pumps
        // samples right after a prior attempt's XPC interruption, and
        // we want to retry from scratch rather than sit on a dead stream.
        streamOutput = StreamOutput()
        streamOutput?.sessionID = sessionID
        let firstFrameSignal = firstFrameSeen
        firstFrameSignal.withLock { $0 = false }
        streamOutput?.onFrameCaptured = { [weak self] pixelBuffer in
            firstFrameSignal.withLock { $0 = true }
            self?.onFrameCaptured?(pixelBuffer)
        }
        streamOutput?.onContentRectChanged = { [weak self] rect in
            self?.onContentRectChanged?(rect)
        }
        streamOutput?.onStreamSample = { [weak self] in
            self?.onStreamSample?()
        }
        streamOutput?.onStreamStopped = { [weak self] error in
            // An in-band `.stopped` frame (e.g. the sole shared window closed)
            // routes through the same owner callback as a delegate stop.
            self?.onStreamStopped?(error)
        }

        if let stream = stream, let output = streamOutput {
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
                logEvent("start.addStreamOutput.ok", extra: "size=\(config.width)x\(config.height)")
            } catch {
                logEvent("start.addStreamOutput.fail", extra: "err=\(error)")
                throw error
            }
        }

        // System-audio output on its own serial queue. Non-fatal on failure:
        // a share that can't add the audio output still delivers video.
        if capturesAudio, let stream = stream {
            let audioOut = AudioStreamOutput()
            audioOut.onAudioSampleBuffer = { [weak self] sampleBuffer in
                self?.onAudioSampleBuffer?(sampleBuffer)
            }
            audioStreamOutput = audioOut
            let audioQueue = DispatchQueue(label: "ScreenCapture.audio.\(sessionID)", qos: .userInitiated)
            do {
                try stream.addStreamOutput(audioOut, type: .audio, sampleHandlerQueue: audioQueue)
                logEvent("start.addAudioOutput.ok")
            } catch {
                logEvent("start.addAudioOutput.fail", extra: "err=\(error)")
                audioStreamOutput = nil
            }
        }

        // Start capture with a 5s watchdog. SCStream's bridged async method
        // occasionally leaks its continuation when the screen-recording
        // daemon errors during startup — observed in the wild as
        // "SWIFT TASK CONTINUATION MISUSE: _createCheckedThrowingContinuation
        // leaked" right after a "Stream stopped with error: ... application
        // connection being interrupted" line. Without the timeout the whole
        // Tailscale server start path hangs forever.
        guard let stream = stream else { return }
        // Use the completion-handler variant of startCapture. The bridged
        // async `try await stream.startCapture()` has been observed leaking
        // its CheckedContinuation when the screen-recording daemon errors
        // during startup, hanging the whole Tailscale server start path.
        // Wrapping the completion handler ourselves plus a 5s watchdog gives
        // a deterministic exit in either direction.
        let startCallNs = DispatchTime.now().uptimeNanoseconds
        logEvent("start.startCapture.call")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(cont)
            let pendingLock = pendingStart
            pendingLock.withLock { $0 = box }
            let sid = sessionID
            stream.startCapture { error in
                let ms = (DispatchTime.now().uptimeNanoseconds &- startCallNs) / 1_000_000
                pendingLock.withLock { $0 = nil }
                if let error = error {
                    print("ScreenCapture[\(sid)] startCapture.completion.error after \(ms)ms err=\(error)")
                    box.resume(throwing: error)
                } else {
                    print("ScreenCapture[\(sid)] startCapture.completion.ok after \(ms)ms")
                    box.resume()
                }
            }
            // Cold-start watchdog. Apple's startCapture has been observed
            // to never resolve when replayd's XPC link drops mid-handshake;
            // the SCStreamDelegate's didStopWithError fires (handled below)
            // and otherwise this 10s timer is the deterministic exit. 10s
            // covers a slow first-run permission grant without leaving the
            // user staring forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                pendingLock.withLock { $0 = nil }
                print("ScreenCapture[\(sid)] startCapture.watchdog.fired after 10000ms")
                Self.bundlePoisonedAtNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
                box.resume(throwing: ScreenCaptureError.startTimeout)
            }
        }

        // startCapture has acked. Wait for the first sample to confirm
        // replayd is actually pumping — if it isn't (post-XPC-interrupt
        // half-dead state) the caller's retry loop will tear the stream
        // down and bring up a fresh one.
        try await waitForFirstFrame(timeout: .seconds(3))
    }

    private func waitForFirstFrame(timeout: Duration) async throws {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadlineNs = startNs &+ UInt64(timeout.components.seconds) * 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            if firstFrameSeen.withLock({ $0 }) {
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
                logEvent("waitForFirstFrame.gotFrame", extra: "after=\(elapsedMs)ms")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
        logEvent("waitForFirstFrame.timeout", extra: "after=\(elapsedMs)ms (no samples — replayd silent)")
        Self.bundlePoisonedAtNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        throw ScreenCaptureError.noFramesDelivered
    }

    /// Dedupes CheckedContinuation resumptions so we can race Apple's
    /// completion handler against a timeout without double-resuming.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
        func resume() {
            lock.lock()
            defer { lock.unlock() }
            cont?.resume()
            cont = nil
        }
        func resume(throwing error: Error) {
            lock.lock()
            defer { lock.unlock() }
            cont?.resume(throwing: error)
            cont = nil
        }
    }

    func stop() async {
        logEvent("stop.begin")
        // Mark the output stopping FIRST: `stopCapture()` below makes SCStream
        // emit a `.stopped` status frame, and without this flag the output's
        // in-band stop bridge would misread that deliberate stop as a window
        // vanishing — turning a changeSource helper swap into a phantom crash.
        streamOutput?.beginStopping()
        // Clear callbacks before tearing the SCStream down. The
        // SCStreamDelegate.didStopWithError can fire asynchronously *after*
        // `stopCapture()` returns; if a new ScreenCapture has been
        // installed in the meantime that late callback would route through
        // the old wrapper and trigger another `stopSharing`, killing the
        // freshly started session. Nilling the callbacks first means the
        // late delegate fire is a no-op.
        onFrameCaptured = nil
        onStreamStopped = nil
        onAudioSampleBuffer = nil
        if let stream = stream {
            // Explicitly remove the stream output BEFORE stopCapture.
            // Without this, replayd may keep the bundle's screen-
            // capture slot reserved for a few seconds after stop,
            // refusing fresh startCapture calls with "application
            // connection being interrupted" or noFramesDelivered. The
            // throwaway `try?` is intentional — removeStreamOutput
            // throws if the output isn't installed (the bring-up
            // failed before addStreamOutput), which is benign.
            if let out = streamOutput {
                do {
                    try stream.removeStreamOutput(out, type: .screen)
                    logEvent("stop.removeStreamOutput.ok")
                } catch {
                    logEvent("stop.removeStreamOutput.fail", extra: "err=\(error)")
                }
            } else {
                logEvent("stop.removeStreamOutput.skip", extra: "streamOutput=nil")
            }
            if let audioOut = audioStreamOutput {
                do {
                    try stream.removeStreamOutput(audioOut, type: .audio)
                    logEvent("stop.removeAudioOutput.ok")
                } catch {
                    logEvent("stop.removeAudioOutput.fail", extra: "err=\(error)")
                }
            }
            await Self.stopCaptureWatchdogged(stream: stream, sessionID: sessionID)
        } else {
            logEvent("stop.skip", extra: "stream=nil")
        }
        stream = nil
        streamOutput = nil
        audioStreamOutput = nil
        streamConfig = nil
        Self.lastStopAtNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        logEvent("stop.end")
    }

    /// Wraps `SCStream.stopCapture(completionHandler:)` in a 3 s
    /// watchdog. Apple's bridged `stopCapture()` async variant has been
    /// observed to leak its CheckedContinuation when the stream is
    /// already in a broken state (e.g. immediately after replayd
    /// dropped its XPC link mid-startCapture). Without this, the await
    /// here hangs forever, hanging `capture.stop` → `server.stop` →
    /// `AppState.stopSharing`. Logs the leaked-continuation warning
    /// from Apple are visible in the merged log; we route around them
    /// by ignoring the completion entirely after the deadline.
    ///
    /// Logs a warning when the watchdog fires before completion —
    /// when that happens the SCStream is still in Apple's "stopping"
    /// state and macOS's screen-recording badge will stay on until
    /// the process exits or replayd is restarted.
    private static func stopCaptureWatchdogged(stream: SCStream, sessionID: String) async {
        let startedNs = DispatchTime.now().uptimeNanoseconds
        let watchdogFired = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let box = StopCaptureBox(cont)
            stream.stopCapture { err in
                let ms = (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000
                let errStr = err.map { "err=\($0)" } ?? "err=nil"
                print("ScreenCapture[\(sessionID)] stopCapture.completion.invoked after \(ms)ms \(errStr)")
                box.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.resume(returning: true)
            }
        }
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000
        if watchdogFired {
            print(
                "ScreenCapture[\(sessionID)] stopCapture.watchdog.fired after \(elapsedMs)ms (completion handler never invoked — replayd state orphaned)"
            )
        }
    }

    private final class StopCaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
        func resume(returning value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            cont?.resume(returning: value)
            cont = nil
        }
    }

    func captureFrame() {
        // Frames are captured automatically via the stream output
    }
}

extension ScreenCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let pendingExisted = pendingStart.withLock { $0 != nil }
        logEvent(
            "delegate.didStopWithError",
            extra: "domain=\(domain) code=\(code) pendingStart=\(pendingExisted) desc=\"\(error.localizedDescription)\""
        )
        // If this fires while `start()` is still awaiting startCapture, fail
        // the start immediately rather than letting the 10s watchdog burn —
        // replayd is telling us the bring-up isn't going to complete.
        let pending = pendingStart.withLock { box -> ContinuationBox? in
            let b = box
            box = nil
            return b
        }
        if let pending {
            pending.resume(throwing: error)
            return
        }
        onStreamStopped?(error)
    }
}

private class StreamOutput: NSObject, SCStreamOutput {
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
    /// Forward up to ScreenCapture so its owner can react to window
    /// resizes (debounce + `updateConfiguration` to push new buffer
    /// dims through the stream). Fires on the same edge as the
    /// `contentRect` log line below.
    var onContentRectChanged: ((CGRect) -> Void)?
    /// Forwarded ~1 Hz on any delivered sample (see `ScreenCapture.onStreamSample`).
    var onStreamSample: (() -> Void)?
    /// Fired once when a delivered sample carries `SCFrameStatus.stopped` —
    /// the stream ended in-band rather than via the delegate's
    /// `didStopWithError`. Closing the sole shared window takes this path on
    /// some macOS versions: no delegate error ever fires, and the `.stopped`
    /// status frame still ticks the heartbeat below, so without this bridge
    /// the parent's hung-helper watchdog can't trip and the share hangs
    /// "sharing" forever with dead capture.
    var onStreamStopped: ((Error?) -> Void)?
    /// Latches after the first `.stopped` frame so `onStreamStopped` fires once
    /// even if SCStream keeps delivering stopped frames. Serial queue → no lock.
    private var didSignalStop = false
    /// Set by `ScreenCapture.stop()` before it tears the stream down. A
    /// *deliberate* stop (Stop Sharing, the changeSource helper swap) makes
    /// SCStream deliver a `.stopped` frame too — we must NOT treat that as a
    /// window-vanish, or the changeSource helper swap looks like a crash and
    /// races a spurious auto-restart against the new helper (slot refusal →
    /// share torn down). Cross-thread: written on the MainActor, read on the
    /// sample-handler queue, so it takes a lock.
    private let stopping = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Mark the output as intentionally stopping so a subsequent `.stopped`
    /// status frame is ignored rather than bridged to `onStreamStopped`.
    func beginStopping() {
        stopping.withLock { $0 = true }
    }
    /// Last time `onStreamSample` was forwarded, for the 1 Hz throttle. Touched
    /// only on the serial sample-handler queue, so it needs no lock.
    private var lastSampleNotifyNs: UInt64 = 0
    var sessionID: String = "????"
    private var deliveredCount: Int = 0
    private var droppedCount: Int = 0
    /// Last logged SCStreamFrameInfo.contentRect for change detection.
    /// SCStream's buffer dims are pinned at start but the source rect
    /// inside the buffer updates as the shared window resizes — logging
    /// changes here tells us whether SCStream is following the window
    /// without needing `stream.updateConfiguration`.
    private var lastContentRect: CGRect = .zero

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Decode SCStreamFrameInfo.status from the sample buffer's
        // attachments. SCStream delivers a sample for every state
        // change — `.idle` (nothing changed), `.blank` (display
        // sleeping), `.suspended` (capture paused) all arrive with
        // no imageBuffer. Logging the status the first few times
        // tells us whether replayd is genuinely silent or just
        // sending status pings without pixel data.
        let statusValue = Self.frameStatusValue(from: sampleBuffer)
        let status = Self.frameStatusString(statusValue)
        let hasImage = sampleBuffer.imageBuffer != nil

        // In-band stream stop: closing the sole shared window can arrive as a
        // `.stopped` status frame instead of a delegate `didStopWithError`.
        // Bridge it to `onStreamStopped` *before* the heartbeat below —
        // otherwise the `.stopped` frame ticks liveness, masking the
        // hung-helper watchdog, and the share never tears down. Latched so
        // repeated stopped frames signal only once.
        if statusValue == .stopped, !stopping.withLock({ $0 }) {
            if !didSignalStop {
                didSignalStop = true
                print("StreamOutput[\(sessionID)] frame status=.stopped — signalling stream stop")
                onStreamStopped?(nil)
            }
            return
        }

        // Liveness: the delegate fires for every delivered sample, including
        // `.idle` frames on a static screen, so this is a content-independent
        // proof the capture pipeline is alive — exactly what the parent's
        // hung-helper watchdog needs (a starved encoder produces no AUs even
        // when capture is healthy). Throttle to ~1 Hz before forwarding it as a
        // heartbeat; this runs on the serial sample-handler queue so
        // `lastSampleNotifyNs` needs no lock.
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if nowNs &- lastSampleNotifyNs >= 1_000_000_000 {
            lastSampleNotifyNs = nowNs
            onStreamSample?()
        }

        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else {
            droppedCount += 1
            if droppedCount <= 5 || droppedCount % 60 == 0 {
                print(
                    "StreamOutput[\(sessionID)] dropped #\(droppedCount) type=\(type) status=\(status) hasImage=\(hasImage)"
                )
            }
            return
        }

        deliveredCount += 1
        if deliveredCount == 1 || deliveredCount % 120 == 0 {
            print("StreamOutput[\(sessionID)] delivered #\(deliveredCount) status=\(status)")
        }

        // Log the per-frame contentRect when it changes — this is the
        // source rect within the configured buffer. If it changes while
        // CVPixelBufferGetWidth/Height stay constant, SCStream is
        // following the window but the buffer dims are pinned; we'd need
        // `stream.updateConfiguration` to track the resize end-to-end.
        let contentRect = Self.contentRect(from: sampleBuffer)
        if let r = contentRect, !Self.cgRectsClose(r, lastContentRect) {
            let bufW = CVPixelBufferGetWidth(pixelBuffer)
            let bufH = CVPixelBufferGetHeight(pixelBuffer)
            print(
                String(
                    format:
                        "StreamOutput[%@] contentRect %.0fx%.0f@(%.0f,%.0f) buf=%dx%d frame#%d",
                    sessionID, r.width, r.height, r.origin.x, r.origin.y, bufW, bufH, deliveredCount)
            )
            lastContentRect = r
            onContentRectChanged?(r)
        }
        onFrameCaptured?(pixelBuffer)
    }

    /// Returns true when two rects match within 0.5 pt on every edge —
    /// floats from `CGRect(dictionaryRepresentation:)` jitter slightly
    /// between identical frames.
    private static func cgRectsClose(_ a: CGRect, _ b: CGRect) -> Bool {
        let eps: CGFloat = 0.5
        return abs(a.origin.x - b.origin.x) < eps
            && abs(a.origin.y - b.origin.y) < eps
            && abs(a.width - b.width) < eps
            && abs(a.height - b.height) < eps
    }

    /// Pull `SCStreamFrameInfo.contentRect` out of the sample buffer's
    /// attachments. SCStream encodes this as a CFDictionary describing
    /// the source rect (within the configured output buffer) of the
    /// actual captured content for this frame.
    private static func contentRect(from sb: CMSampleBuffer) -> CGRect? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[CFString: Any]],
            let attachment = attachments.first,
            let dict = attachment[SCStreamFrameInfo.contentRect as CFString]
                as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    /// Pull the raw `SCStreamFrameInfo.status` enum out of the sample buffer's
    /// attachments. `nil` when the attachment is missing/undecodable.
    private static func frameStatusValue(from sb: CMSampleBuffer) -> SCFrameStatus? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[CFString: Any]],
            let attachment = attachments.first,
            let raw = attachment[SCStreamFrameInfo.status as CFString] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// Human-readable name for a decoded `SCFrameStatus` (nil ⇒ "unknown").
    private static func frameStatusString(_ status: SCFrameStatus?) -> String {
        guard let status else { return "unknown" }
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        @unknown default: return "raw(\(status.rawValue))"
        }
    }
}

/// Minimal `SCStreamOutput` for the `.audio` stream type. Kept separate from
/// `StreamOutput` (video) so each runs on its own serial queue without sharing
/// unlocked counters. Forwards the raw audio sample buffer up to
/// `ScreenCapture.onAudioSampleBuffer`.
private final class AudioStreamOutput: NSObject, SCStreamOutput {
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onAudioSampleBuffer?(sampleBuffer)
    }
}

enum ScreenCaptureError: Error {
    case startTimeout
    /// startCapture resolved successfully but no sample buffers arrived
    /// before the first-frame watchdog expired. Retriable — usually a
    /// half-dead replayd left over from a previous interrupted bring-up.
    case noFramesDelivered
    /// A prior SCStream wedged replayd's per-bundle slot. Recovery
    /// requires process exit — retries within the same process all
    /// fail the same way. Surfaced so AppState can show a clear
    /// "restart Tailscreen" alert instead of looping.
    case bundleSlotPoisoned
}
