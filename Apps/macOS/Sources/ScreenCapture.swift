import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import os

class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    /// Own serial queue, kept distinct from `streamOutput` so its
    /// queue-confined counters are never touched from a second thread. Nil
    /// unless `capturesAudio` was set before start.
    private var audioStreamOutput: AudioStreamOutput?
    /// When set before `start(...)`, captures 48kHz mono system audio.
    /// `excludesCurrentProcessAudio` keeps played-back viewer voices from
    /// being re-captured. Set by the capture-helper from
    /// `PickerSelection.captureAudio`.
    var capturesAudio: Bool = false
    /// Fires on the dedicated audio-output queue, straight into a
    /// `SystemAudioTap` with no MainActor hop.
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// So `updateConfiguration` can preserve frame-interval/pixel-format/
    /// queueDepth across resize-driven updates and only change width/height.
    private var streamConfig: SCStreamConfiguration?
    /// Kept so callers can multiply point-sized contentRect changes through
    /// to pixel dims without re-querying the filter.
    private(set) var pointPixelScale: Float = 1
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
    /// Fires when `SCStreamFrameInfo.contentRect` changes by >=0.5pt. Drives
    /// `updateConfiguration` so the encoder buffer follows window resizes.
    var onContentRectChanged: ((CGRect) -> Void)?
    /// Throttled to ~1Hz; fires for *any* sample including `.idle` frames, so
    /// it stays alive on a static screen unlike `onFrameCaptured`. Forwarded
    /// as a heartbeat for the parent's hung-helper watchdog.
    var onStreamSample: (() -> Void)?
    var onStreamStopped: ((Error?) -> Void)?

    /// Short tag for cross-referencing lifecycle log lines across concurrent
    /// attempts.
    private let sessionID = String(format: "%04x", UInt16.random(in: 0...0xFFFF))
    private let createdAtNs: UInt64 = DispatchTime.now().uptimeNanoseconds

    /// Short windows since the prior `stopCapture` correlate with replayd's
    /// "interrupted"/"noFramesDelivered" cool-down failures.
    private static let lastStopAtNs = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    /// Timestamp of the most recent observation that replayd's per-bundle
    /// slot was wedged. Inside the cool-down window, new sessions refuse
    /// early with a clear error instead of doomed retries; outside it,
    /// replayd sometimes recovers on its own so we let them try again.
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
    /// fires `didStopWithError` synchronously without resolving the
    /// startCapture completion handler, so the delegate error tees into this
    /// box to fail fast instead of waiting for the watchdog.
    private let pendingStart = OSAllocatedUnfairLock<ContinuationBox?>(initialState: nil)

    /// Flips true on the first delivered sample. If none arrives within the
    /// watchdog window, throws a retriable error — replayd is awake but not pumping.
    private let firstFrameSeen = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Once a TCC prompt is denied it never re-fires; this is the only recovery.
    @MainActor
    static func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Refuses early if a prior session poisoned replayd's per-bundle slot,
    /// else sleeps out the post-stop cool-down.
    private func applyStartCooldowns() async throws {
        if let poisonedAt = Self.bundlePoisonedAtNs.withLock({ $0 }) {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- poisonedAt
            if elapsedNs < Self.bundlePoisonCooldownNs {
                let remainMs = (Self.bundlePoisonCooldownNs - elapsedNs) / 1_000_000
                logEvent("start.refused", extra: "bundleSlotPoisoned remaining=\(remainMs)ms")
                throw ScreenCaptureError.bundleSlotPoisoned
            }
            // Cool-down elapsed; clear and let the attempt proceed.
            Self.bundlePoisonedAtNs.withLock { $0 = nil }
            logEvent("start.poison.cleared", extra: "elapsed=\(elapsedNs / 1_000_000)ms")
        }
        // Starting within ~1s of the last stop makes the new SCStream
        // immediately fire didStopWithError(-3805 "application connection
        // being interrupted"), which poisons the bundle's slot until process
        // exit. Waiting out the cool-down avoids the poison entirely.
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

    /// H.264/HEVC 4:2:0 require even width and height; an odd dimension can
    /// encode fine on the sharer's VideoToolbox yet show a garbage edge
    /// column or chroma shift on a different decoder. Rounds down to never
    /// encode past the captured region.
    private static func evenFloor(_ value: Int) -> Int {
        max(2, value & ~1)
    }

    /// `fps` caps the SCStream's delivery rate via `minimumFrameInterval` so
    /// the stream and encoder agree. `colorInfo` selects the capture pixel
    /// format and `colorSpaceName`; the shipped BT.709 8-bit default leaves both untouched.
    func start(filter: SCContentFilter, fps: Int = 60, colorInfo: ColorInfo = .bt709FullRange8) async throws {
        try await applyStartCooldowns()
        // contentRect is in points; multiply by pointPixelScale for pixel dims.
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

    /// Sized in pixels — callers multiply contentRect's point dims by
    /// `pointPixelScale` first. Preserves every other config property; a
    /// tear-down + restart would force a replayd cool-down + bundle slot dance.
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
            return  // already at the requested size
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

    /// Same live-reconfig path as `updateConfiguration(pixelWidth:pixelHeight:)`.
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
        // Full-range biplanar 4:2:0 matches VideoToolbox natively (skips a
        // BGRA->YUV conversion and a 601/709 ambiguity that crushed
        // near-black UI). `ColorInfo` picks 8-bit vs 10-bit for HDR sources.
        config.pixelFormat = colorInfo.capturePixelFormat
        // Only set for non-709 gamuts; BT.709 leaves SCStream at its default.
        if let colorSpaceName = colorInfo.captureColorSpaceName {
            config.colorSpaceName = colorSpaceName
        }
        config.showsCursor = true
        config.queueDepth = 5
        if capturesAudio {
            // Matches the voice codec (mono 48kHz) so both ends round-trip
            // unchanged. `excludesCurrentProcessAudio` keeps played-back
            // viewer voices from looping back as system audio.
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

        stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Tee first-frame arrival through firstFrameSeen: replayd sometimes
        // acks startup but never pumps samples after a prior XPC
        // interruption, and we want to retry from scratch rather than sit on
        // a dead stream.
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

        // Non-fatal on failure: a share that can't add the audio output
        // still delivers video.
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

        // The bridged async `try await stream.startCapture()` has been
        // observed leaking its CheckedContinuation when the screen-recording
        // daemon errors during startup, hanging the server start path
        // forever. Wrapping the completion handler with our own watchdog
        // gives a deterministic exit either way.
        guard let stream = stream else { return }
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
            // startCapture can never resolve when replayd's XPC link drops
            // mid-handshake; 10s covers a slow first-run permission grant.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                pendingLock.withLock { $0 = nil }
                print("ScreenCapture[\(sid)] startCapture.watchdog.fired after 10000ms")
                Self.bundlePoisonedAtNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
                box.resume(throwing: ScreenCaptureError.startTimeout)
            }
        }

        // Confirm replayd is actually pumping; if not, the caller's retry
        // loop tears the stream down and brings up a fresh one.
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

    /// Dedupes resumptions so a completion handler racing a timeout can't
    /// double-resume.
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
        // First, or `stopCapture()`'s in-band `.stopped` frame reads as a
        // window vanishing, turning a changeSource swap into a phantom crash.
        streamOutput?.beginStopping()
        // Before tearing the stream down: `didStopWithError` can fire
        // asynchronously after `stopCapture()` returns, and if a new
        // ScreenCapture is already installed, a late callback through the
        // old wrapper would kill the freshly started session.
        onFrameCaptured = nil
        onStreamStopped = nil
        onAudioSampleBuffer = nil
        if let stream = stream {
            // Explicitly remove BEFORE stopCapture, or replayd may keep the
            // bundle's slot reserved for a few seconds, refusing fresh starts.
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

    /// 3s watchdog: Apple's bridged `stopCapture()` has been observed to leak
    /// its continuation when the stream is already broken, hanging
    /// `capture.stop` -> `server.stop` -> `AppState.stopSharing` forever. If
    /// the watchdog fires first, the SCStream stays in Apple's "stopping"
    /// state and the recording badge stays on until process exit/replayd restart.
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
        // Frames are captured automatically via the stream output.
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
        // If start() is still awaiting startCapture, fail immediately rather
        // than letting the 10s watchdog burn.
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
    var onContentRectChanged: ((CGRect) -> Void)?
    /// Forwarded ~1Hz on any delivered sample.
    var onStreamSample: (() -> Void)?
    /// Closing the sole shared window can end the stream in-band via
    /// `SCFrameStatus.stopped` rather than the delegate's `didStopWithError`
    /// on some macOS versions; without this bridge the hung-helper watchdog
    /// can't trip and the share hangs forever.
    var onStreamStopped: ((Error?) -> Void)?
    /// Latches so `onStreamStopped` fires once even with repeated stopped
    /// frames. Serial queue -> no lock.
    private var didSignalStop = false
    /// Set by `ScreenCapture.stop()` before teardown, so a deliberate stop's
    /// `.stopped` frame isn't mistaken for a window vanishing (which would
    /// race a spurious auto-restart against the changeSource swap). Written
    /// on MainActor, read on the sample-handler queue.
    private let stopping = OSAllocatedUnfairLock<Bool>(initialState: false)

    func beginStopping() {
        stopping.withLock { $0 = true }
    }
    /// Touched only on the serial sample-handler queue, so no lock needed.
    private var lastSampleNotifyNs: UInt64 = 0
    var sessionID: String = "????"
    private var deliveredCount: Int = 0
    private var droppedCount: Int = 0
    /// SCStream's buffer dims are pinned at start, but the source rect inside
    /// updates as the window resizes — this tells us whether SCStream
    /// follows the window without `stream.updateConfiguration`.
    private var lastContentRect: CGRect = .zero

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // `.idle`/`.blank`/`.suspended` all arrive with no imageBuffer;
        // logging status tells replayd-silent apart from status-only pings.
        let statusValue = Self.frameStatusValue(from: sampleBuffer)
        let status = Self.frameStatusString(statusValue)
        let hasImage = sampleBuffer.imageBuffer != nil

        // Must bridge before the heartbeat below, or the `.stopped` frame
        // ticks liveness and masks the hung-helper watchdog.
        if statusValue == .stopped, !stopping.withLock({ $0 }) {
            if !didSignalStop {
                didSignalStop = true
                print("StreamOutput[\(sessionID)] frame status=.stopped — signalling stream stop")
                onStreamStopped?(nil)
            }
            return
        }

        // Content-independent liveness proof (fires even on `.idle` frames),
        // throttled to ~1Hz for the hung-helper watchdog.
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

    /// Within 0.5pt — floats from `CGRect(dictionaryRepresentation:)` jitter
    /// slightly between identical frames.
    private static func cgRectsClose(_ a: CGRect, _ b: CGRect) -> Bool {
        let eps: CGFloat = 0.5
        return abs(a.origin.x - b.origin.x) < eps
            && abs(a.origin.y - b.origin.y) < eps
            && abs(a.width - b.width) < eps
            && abs(a.height - b.height) < eps
    }

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

    /// `nil` when the attachment is missing/undecodable.
    private static func frameStatusValue(from sb: CMSampleBuffer) -> SCFrameStatus? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[CFString: Any]],
            let attachment = attachments.first,
            let raw = attachment[SCStreamFrameInfo.status as CFString] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

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

/// Kept separate from `StreamOutput` (video) so each runs on its own serial
/// queue without sharing unlocked counters.
private final class AudioStreamOutput: NSObject, SCStreamOutput {
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onAudioSampleBuffer?(sampleBuffer)
    }
}

enum ScreenCaptureError: Error {
    case startTimeout
    /// Retriable — usually a half-dead replayd left over from a previous
    /// interrupted bring-up.
    case noFramesDelivered
    /// Recovery requires process exit — retries within the process all fail
    /// the same way; surfaced so AppState shows "restart Tailscreen" instead
    /// of looping.
    case bundleSlotPoisoned
}
