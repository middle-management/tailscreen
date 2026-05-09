import ScreenCaptureKit
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import os

/// Serializable summary of an SCDisplay so AppState can expose a display
/// picker in the menu without exposing ScreenCaptureKit types to the UI.
struct DisplayInfo: Identifiable, Sendable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}

class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var availableContent: SCShareableContent?
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
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

    static func requestPermission() async throws {
        // Request permission by attempting to get shareable content
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Non-prompting probe for Screen Recording authorization. Returns true
    /// once the user has granted access in System Settings → Privacy &
    /// Security. Used to gate eager `SCShareableContent` calls so the menu
    /// doesn't trigger a TCC prompt at first launch.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Enumerate the displays the user can share. Uses `NSScreen` so
    /// the main process never has to touch `SCShareableContent` —
    /// fetching shareable content registers the *parent* with `replayd`,
    /// which then refuses the helper child's `SCStream` with
    /// "application connection being interrupted". `NSScreen` reads
    /// from a separate, screen-recording-permission-free path.
    static func listDisplays() async throws -> [DisplayInfo] {
        return NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID else {
                return nil
            }
            let scale = screen.backingScaleFactor
            let pxWidth = Int(screen.frame.width * scale)
            let pxHeight = Int(screen.frame.height * scale)
            return DisplayInfo(
                id: displayID,
                name: screen.localizedName,
                width: pxWidth,
                height: pxHeight
            )
        }
    }

    private static func humanName(for display: SCDisplay, index: Int) -> String {
        // SCDisplay has no public name. Fall back to the matching NSScreen's
        // localizedName (macOS 14+) if we can find it by CGDirectDisplayID.
        if #available(macOS 14.0, *) {
            for screen in NSScreen.screens {
                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                if screenID == display.displayID {
                    return screen.localizedName
                }
            }
        }
        return "Display \(index + 1)"
    }

    func start(displayID: CGDirectDisplayID? = nil) async throws {
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
        // Get available content. SCShareableContent's bridged async call
        // can hang for a while on first launch while macOS resolves the
        // Screen Recording permission and brings up the screencapture
        // daemon. 5s was too aggressive — first-time permission grants
        // routinely take longer than that. 30s is generous enough for
        // a fresh machine while still bounded.
        logEvent("start.fetchShareableContent.begin")
        availableContent = try await Self.fetchShareableContent(timeout: .seconds(30))
        let displayCount = availableContent?.displays.count ?? 0
        logEvent("start.fetchShareableContent.done", extra: "displays=\(displayCount)")

        let display: SCDisplay
        if let wanted = displayID,
           let match = availableContent?.displays.first(where: { $0.displayID == wanted }) {
            display = match
        } else if let first = availableContent?.displays.first {
            display = first
        } else {
            throw ScreenCaptureError.noDisplayAvailable
        }

        // Capture at the display's native pixel resolution. SCDisplay reports
        // width/height in points, so we multiply by the main screen's backing
        // scale factor (1 on non-Retina, 2 or 3 on Retina).
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 1)
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * scale
        config.height = Int(display.height) * scale
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Full-range NV12 — matches what VideoToolbox wants natively, so the
        // encoder skips an internal BGRA→YUV conversion (cheaper, and removes
        // a 601/709 ambiguity that was crushing near-black UI surfaces under
        // the limited-range default). The encoder tags the bitstream
        // full-range so the decoder reads the right range from the VUI.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 5
        logEvent("start.config", extra: "displayID=\(display.displayID) size=\(config.width)x\(config.height) fps=60 pixelFormat=420f queueDepth=5")

        // Create content filter for the main display
        let filter = SCContentFilter(display: display, excludingWindows: [])

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

        if let stream = stream, let output = streamOutput {
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
                logEvent("start.addStreamOutput.ok", extra: "size=\(config.width)x\(config.height)")
            } catch {
                logEvent("start.addStreamOutput.fail", extra: "err=\(error)")
                throw error
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

    /// Watchdogged `SCShareableContent.excludingDesktopWindows`. The
    /// completion-handler variant exists since macOS 14, so we don't have
    /// to fight Swift Concurrency over a leaked continuation here either.
    private static func fetchShareableContent(timeout: Duration) async throws -> SCShareableContent {
        // Smuggle SCShareableContent through @unchecked Sendable wrap;
        // it isn't Sendable but it's effectively read-only after delivery
        // and we hand it off on a controlled boundary.
        let wrapped: ShareableContentWrap = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShareableContentWrap, Error>) in
            let box = ShareableContentBox(cont)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error = error {
                    box.resume(throwing: error)
                } else if let content = content {
                    box.resume(returning: ShareableContentWrap(value: content))
                } else {
                    box.resume(throwing: ScreenCaptureError.noDisplayAvailable)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout.components.seconds)) {
                box.resume(throwing: ScreenCaptureError.startTimeout)
            }
        }
        return wrapped.value
    }

    private struct ShareableContentWrap: @unchecked Sendable {
        let value: SCShareableContent
    }

    private final class ShareableContentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<ShareableContentWrap, Error>?
        init(_ cont: CheckedContinuation<ShareableContentWrap, Error>) { self.cont = cont }
        func resume(returning value: ShareableContentWrap) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(returning: value); cont = nil
        }
        func resume(throwing error: Error) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(throwing: error); cont = nil
        }
    }

    /// Dedupes CheckedContinuation resumptions so we can race Apple's
    /// completion handler against a timeout without double-resuming.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
        func resume() {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(); cont = nil
        }
        func resume(throwing error: Error) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(throwing: error); cont = nil
        }
    }

    func stop() async {
        logEvent("stop.begin")
        // Clear callbacks before tearing the SCStream down. The
        // SCStreamDelegate.didStopWithError can fire asynchronously *after*
        // `stopCapture()` returns; if a new ScreenCapture has been
        // installed in the meantime that late callback would route through
        // the old wrapper and trigger another `stopSharing`, killing the
        // freshly started session. Nilling the callbacks first means the
        // late delegate fire is a no-op.
        onFrameCaptured = nil
        onStreamStopped = nil
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
            await Self.stopCaptureWatchdogged(stream: stream, sessionID: sessionID)
        } else {
            logEvent("stop.skip", extra: "stream=nil")
        }
        stream = nil
        streamOutput = nil
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
            print("ScreenCapture[\(sessionID)] stopCapture.watchdog.fired after \(elapsedMs)ms (completion handler never invoked — replayd state orphaned)")
        }
    }

    private final class StopCaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
        func resume(returning value: Bool) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(returning: value); cont = nil
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
            let b = box; box = nil; return b
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
    var sessionID: String = "????"
    private var deliveredCount: Int = 0
    private var droppedCount: Int = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Decode SCStreamFrameInfo.status from the sample buffer's
        // attachments. SCStream delivers a sample for every state
        // change — `.idle` (nothing changed), `.blank` (display
        // sleeping), `.suspended` (capture paused) all arrive with
        // no imageBuffer. Logging the status the first few times
        // tells us whether replayd is genuinely silent or just
        // sending status pings without pixel data.
        let status = Self.frameStatus(from: sampleBuffer)
        let hasImage = sampleBuffer.imageBuffer != nil

        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else {
            droppedCount += 1
            if droppedCount <= 5 || droppedCount % 60 == 0 {
                print("StreamOutput[\(sessionID)] dropped #\(droppedCount) type=\(type) status=\(status) hasImage=\(hasImage)")
            }
            return
        }

        deliveredCount += 1
        if deliveredCount == 1 || deliveredCount % 120 == 0 {
            print("StreamOutput[\(sessionID)] delivered #\(deliveredCount) status=\(status)")
        }
        onFrameCaptured?(pixelBuffer)
    }

    /// Pull `SCStreamFrameInfo.status` out of the sample buffer's
    /// attachments. Returns a human-readable string.
    private static func frameStatus(from sb: CMSampleBuffer) -> String {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
              let attachment = attachments.first,
              let raw = attachment[SCStreamFrameInfo.status as CFString] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return "unknown" }
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

enum ScreenCaptureError: Error {
    case noDisplayAvailable
    case permissionDenied
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
