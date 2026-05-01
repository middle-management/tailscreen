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

class ScreenCapture: NSObject {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var availableContent: SCShareableContent?
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
    /// Fires when the SCStream terminates on its own — e.g. user clicked the
    /// menubar "Stop Screen Recording" item, or the stream hit an error.
    var onStreamStopped: ((Error?) -> Void)?

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

    /// Enumerate the displays the user can share. Returns an empty array if
    /// permission has not been granted yet.
    static func listDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.enumerated().map { idx, d in
            DisplayInfo(
                id: d.displayID,
                name: Self.humanName(for: d, index: idx),
                width: Int(d.width),
                height: Int(d.height)
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
        // Get available content. SCShareableContent's bridged async call
        // can hang for a while on first launch while macOS resolves the
        // Screen Recording permission and brings up the screencapture
        // daemon. 5s was too aggressive — first-time permission grants
        // routinely take longer than that. 30s is generous enough for
        // a fresh machine while still bounded.
        print("ScreenCapture: requesting shareable content…")
        availableContent = try await Self.fetchShareableContent(timeout: .seconds(30))
        let displayCount = availableContent?.displays.count ?? 0
        print("ScreenCapture: got \(displayCount) display(s)")

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
        let firstFrameSignal = firstFrameSeen
        firstFrameSignal.withLock { $0 = false }
        streamOutput?.onFrameCaptured = { [weak self] pixelBuffer in
            firstFrameSignal.withLock { $0 = true }
            self?.onFrameCaptured?(pixelBuffer)
        }

        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

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
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(cont)
            let pendingLock = pendingStart
            pendingLock.withLock { $0 = box }
            stream.startCapture { error in
                pendingLock.withLock { $0 = nil }
                if let error = error {
                    box.resume(throwing: error)
                } else {
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
                print("ScreenCapture: first frame after \(elapsedMs)ms")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
        print("ScreenCapture: noFramesDelivered after \(elapsedMs)ms — replayd acked startCapture but never pumped a sample. Likely another Tailscreen process holds the bundle's screen-capture slot, or macOS replayd is wedged. Quit other instances or restart Tailscreen.")
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
            await Self.stopCaptureWatchdogged(stream: stream)
        }
        stream = nil
        streamOutput = nil
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
    private static func stopCaptureWatchdogged(stream: SCStream) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let box = StopCaptureBox(cont)
            stream.stopCapture { _ in
                box.resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.resume()
            }
        }
    }

    private final class StopCaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Never>?
        init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }
        func resume() {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(); cont = nil
        }
    }

    func captureFrame() {
        // Frames are captured automatically via the stream output
    }
}

extension ScreenCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        onFrameCaptured?(pixelBuffer)
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
}
