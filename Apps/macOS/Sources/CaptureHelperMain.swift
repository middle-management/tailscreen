import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
// `@preconcurrency` because SCShareableContent isn't Sendable and we
// need to hop the result of `excludingDesktopWindows(_:onScreenWindowsOnly:)`
// back to the @MainActor reconstruction code below. The cross-actor
// send is safe in practice — we use the value once on the same
// actor — but the framework hasn't been audited for Sendable yet.
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import os

/// Entry point for `Tailscreen --capture-helper`. Owns the SCStream
/// + VideoEncoder pipeline; pipes encoded access units back to the
/// main process via stdout. Reads control messages on stdin.
///
/// Exits when:
///   - main sends `shutdown`
///   - SCStream's didStopWithError fires (replayd dropped us)
///   - SIGTERM / SIGINT (main killed us)
enum CaptureHelperMain {
    static func run() -> Never {
        // Save the real stdout (FD 1) and redirect FD 1 → stderr so that
        // every `print()` and any stray write to FD 1 from inside our
        // existing capture stack lands in stderr instead of corrupting
        // the binary frame protocol. The frame writer writes to the
        // saved FD, which is still connected to the parent's pipe.
        let savedStdout = dup(1)
        if savedStdout >= 0 {
            _ = dup2(2, 1)
        }
        let frameFD: Int32 = savedStdout >= 0 ? savedStdout : 1
        let writer = HelperFrameWriter(handle: FileHandle(fileDescriptor: frameFD, closeOnDealloc: false))

        writer.writeLog("capture-helper: awaiting contentFilter on stdin (frameFD=\(frameFD))")
        Task { @MainActor in
            let runner = CaptureHelperRunner(writer: writer)
            installSignalHandlers(writer: writer, runner: runner)
            installStdinReader(writer: writer, runner: runner)
            // Capture starts in `installStdinReader` once the parent
            // delivers the archived `SCContentFilter`.
            //
            // Startup watchdog: if the parent never sends a
            // `contentFilter` frame (e.g. it died mid-spawn or its
            // stdin write was somehow skipped), the helper would
            // otherwise sit on the run loop forever with no SCStream
            // and no exit signal. After 10 s of no `startWithFilter`
            // call, bail with a `permanent:` fatal so the server's
            // crash-budget loop doesn't keep respawning into the
            // same wedge.
            try? await Task.sleep(for: .seconds(10))
            if !runner.hasStarted {
                writer.writeFatal(
                    "permanent: parent never delivered contentFilter within 10s")
                exit(3)
            }
        }
        RunLoop.main.run()
        // RunLoop.main.run() never returns.
        exit(0)
    }

    @MainActor
    private static func installSignalHandlers(writer: HelperFrameWriter, runner: CaptureHelperRunner) {
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigSrc.setEventHandler {
            writer.writeLog("capture-helper: SIGTERM, shutting down")
            Task {
                await runner.shutdown()
                exit(0)
            }
        }
        signal(SIGTERM, SIG_IGN)
        sigSrc.resume()
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigInt.setEventHandler {
            writer.writeLog("capture-helper: SIGINT, shutting down")
            Task {
                await runner.shutdown()
                exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        sigInt.resume()
        // Hold the dispatch sources alive for the process lifetime.
        Self.signalSources = [sigSrc, sigInt]
    }

    @MainActor
    private static func installStdinReader(writer: HelperFrameWriter, runner: CaptureHelperRunner) {
        Thread.detachNewThread {
            let reader = HelperControlReader(handle: FileHandle.standardInput)
            while let (type, payload) = reader.readNext() {
                guard let kind = CaptureHelperWire.InType(rawValue: type) else { continue }
                switch kind {
                case .requestKeyframe:
                    Task { await runner.requestKeyframe() }
                case .setBitrate:
                    let bps = payload.readBE32() ?? 0
                    Task { await runner.setBitrate(Int(bps)) }
                case .setAudioEnabled:
                    let on = (payload.first ?? 0) != 0
                    Task { await runner.setAudioEnabled(on) }
                case .setFrameInterval:
                    let fps = payload.readBE32() ?? 60
                    Task { await runner.setFrameInterval(Int(fps)) }
                case .contentFilter:
                    // Decode the JSON `PickerSelection`, fetch the
                    // shareable content (allowed in the helper —
                    // CLAUDE.md only forbids `SCShareableContent`
                    // calls in the main process), reconstruct the
                    // filter, and start capture. Has to land on the
                    // main actor so the SCStream + VideoToolbox
                    // setup sequence runs on the same thread the
                    // rest of the helper expects.
                    let payloadCopy = payload
                    Task { @MainActor in
                        do {
                            let selection = try JSONDecoder().decode(
                                PickerSelection.self, from: payloadCopy)
                            let filter = try await Self.buildFilter(from: selection)
                            let colorInfo = Self.captureColorInfo(
                                for: selection,
                                env: ProcessInfo.processInfo.environment)
                            await runner.startWithFilter(
                                filter, colorInfo: colorInfo,
                                captureAudio: selection.captureAudio)
                        } catch let error as PickerReconstructionError {
                            // The captured window/display/app no longer
                            // resolves — the user closed it. Non-retryable like
                            // `permanent:`, but tagged `source-gone:` so the
                            // main process can treat it as an expected stop
                            // (a gentle notice) rather than an error alert.
                            writer.writeFatal("source-gone: \(error)")
                            exit(3)
                        } catch {
                            // `permanent:` prefix tells the server's
                            // onUnexpectedExit handler not to burn the
                            // crash-restart budget — re-spawning will
                            // hit the same decode/reconstruct error.
                            writer.writeFatal(
                                "permanent: contentFilter decode/reconstruct failed: \(error)")
                            exit(3)
                        }
                    }
                case .shutdown:
                    Task {
                        await runner.shutdown()
                        exit(0)
                    }
                }
            }
            writer.writeLog("capture-helper: stdin closed, exiting")
            Task {
                await runner.shutdown()
                exit(0)
            }
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Reconstruct an `SCContentFilter` from the primitives the
    /// picker-helper extracted on the other side of the wire. Calls
    /// `SCShareableContent` to resolve the IDs into live SC* objects
    /// — legal here because we're inside the capture-helper, not the
    /// main process. If anything fails to resolve (e.g. the user
    /// quit the window between picking and the helper spawning) the
    /// caller falls back to its existing fatal-error path.
    @MainActor
    static func buildFilter(from selection: PickerSelection) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        switch selection.kind {
        case .display:
            guard let id = selection.displayID,
                let display = content.displays.first(where: { $0.displayID == id })
            else {
                throw PickerReconstructionError.displayNotFound(selection.displayID)
            }
            // App Veil: hide the veiled apps' windows from viewers. The
            // exclusion is by *application*, so new windows of a resolved
            // app stay hidden without a filter rebuild. A veiled app that
            // isn't running can't resolve here — the parent watches for its
            // launch (`AppState`'s NSWorkspace observer) and re-pushes the
            // filter so it gets veiled by the respawned helper.
            let veiledSet = Set(selection.excludedBundleIDs)
            guard !veiledSet.isEmpty else {
                return SCContentFilter(display: display, excludingWindows: [])
            }
            let veiledApps = content.applications.filter {
                veiledSet.contains($0.bundleIdentifier)
            }
            return SCContentFilter(
                display: display, excludingApplications: veiledApps, exceptingWindows: [])
        case .window:
            guard let id = selection.windowID,
                let window = content.windows.first(where: { $0.windowID == id })
            else {
                throw PickerReconstructionError.windowNotFound(selection.windowID)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .application:
            // SCContentFilter's "share these apps" constructor is
            // anchored to a display. The picker tells us which one
            // via `displayID`; if it's missing (rare — the picker
            // always picks a display context for app shares) fall
            // back to the main display.
            let displayID = selection.displayID ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                throw PickerReconstructionError.displayNotFound(displayID)
            }
            let bundleSet = Set(selection.bundleIDs)
            let apps = content.applications.filter { bundleSet.contains($0.bundleIdentifier) }
            return SCContentFilter(
                display: display, including: apps, exceptingWindows: [])
        }
    }

    /// Pick the `ColorInfo` to capture + encode with for this selection.
    /// Phase 1 (Display P3 tagging at 8-bit) is on by default for wide-gamut
    /// displays; 10-bit HEVC Main 10 and HDR (BT.2020 PQ) are opt-in via
    /// `TAILSCREEN_ENABLE_10BIT` / `TAILSCREEN_ENABLE_HDR` and gated on the
    /// display actually being capable. A viewer's 8-bit fallback request
    /// (`TAILSCREEN_FORCE_8BIT`) or codec fallback (`TAILSCREEN_FORCE_H264`,
    /// which forces the 8-bit-only H.264 path) both pin the capture to 8-bit.
    @MainActor
    static func captureColorInfo(for selection: PickerSelection, env: [String: String]) -> ColorInfo {
        let forceH264 = env["TAILSCREEN_FORCE_H264"] == "1"
        let force8bit = env["TAILSCREEN_FORCE_8BIT"] == "1"
        let enable10bit = env["TAILSCREEN_ENABLE_10BIT"] == "1"
        let enableHDR = env["TAILSCREEN_ENABLE_HDR"] == "1"
        let displayID = selection.displayID ?? CGMainDisplayID()
        let wideGamut = displayIsWideGamut(displayID)
        let hdrCapable = enableHDR && displayIsHDR(displayID)
        // 10-bit is HEVC-only (H.264 stays 8-bit) and opt-in; a viewer's
        // 8-bit request overrides.
        let want10 = (enable10bit || hdrCapable) && !forceH264 && !force8bit
        let bitDepth = want10 ? 10 : 8
        return ColorInfo.forDisplay(wideGamut: wideGamut, hdrCapable: hdrCapable, bitDepth: bitDepth)
    }

    /// True when the display renders a wider gamut than sRGB (P3 or better) —
    /// every modern MacBook / Studio Display. Reads the display's assigned
    /// color space; safe on any thread.
    static func displayIsWideGamut(_ displayID: CGDirectDisplayID) -> Bool {
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        return colorSpace.isWideGamutRGB
    }

    /// True when the display advertises EDR headroom above SDR (an XDR / Pro
    /// Display XDR panel). Must run on the main thread (`NSScreen`).
    @MainActor
    static func displayIsHDR(_ displayID: CGDirectDisplayID) -> Bool {
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[screenNumberKey] as? NSNumber
            guard number?.uint32Value == displayID else { continue }
            return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        }
        return false
    }
}

enum PickerReconstructionError: Error {
    case displayNotFound(UInt32?)
    case windowNotFound(UInt32?)
}

extension Data {
    fileprivate func readBE32() -> UInt32? {
        guard count >= 4 else { return nil }
        return self.withUnsafeBytes { raw in
            let b0 = UInt32(raw[0])
            let b1 = UInt32(raw[1])
            let b2 = UInt32(raw[2])
            let b3 = UInt32(raw[3])
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }
}

/// SCStream + VideoEncoder lifecycle inside the helper. Captured
/// pixel buffers go through `VideoEncoder` and the resulting access
/// units are written to the framed wire on stdout instead of fanning
/// out as RTP.
@MainActor
private final class CaptureHelperRunner {
    private let writer: HelperFrameWriter
    private let captureWrapper = ScreenCapture()
    private var encoder: VideoEncoder?
    /// System-audio pipeline (CMSampleBuffer → Opus AU). Created in
    /// `startWithFilter` only when the selection asked for audio capture.
    private var systemAudioTap: SystemAudioTap?
    /// Live enable/disable latch for system-audio *emission*, toggled by the
    /// `setAudioEnabled` wire message. Locked because the tap's encode callback
    /// (SCStream audio queue) reads it while the stdin reader writes it. The
    /// server re-sends the desired value after every (re)spawn.
    private let audioEnabled = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Spawn-time quality knobs (fps cap, codec preference, bandwidth
    /// ceiling) the parent delivered via environment variables — see
    /// `QualitySettings.helperEnvironment()`. Read once: the parent
    /// snapshots settings per share session, so a helper's knobs never
    /// change mid-life (live ceiling changes ride the `setBitrate` wire
    /// message instead).
    private let quality = QualitySettings.fromEnvironment(ProcessInfo.processInfo.environment)
    /// Color characteristics chosen for this share (BT.709 8-bit by default,
    /// Display P3 on wide-gamut displays, BT.2020 PQ 10-bit for opt-in HDR).
    /// Threaded into both the SCStream config (pixel format + colorSpaceName)
    /// and the encoder (color VUI tags + profile) so capture and encode agree.
    private var colorInfo: ColorInfo = .bt709FullRange8
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    /// True once `startWithFilter(_:)` has been called. Read by the
    /// startup watchdog in `CaptureHelperMain.run()`; `fileprivate`
    /// so `CaptureHelperMain` (same file, different type) can read it.
    fileprivate var hasStarted = false

    /// Pending contentRect (points) from the most recent SCStream frame
    /// where the source rect differed from the current buffer. Coalesced
    /// by `resizeDebounceTimer` so a 60 Hz live drag becomes one
    /// `updateConfiguration` per ~200 ms instead of per frame — SCStream
    /// thrashes the pipeline if you reconfigure faster than the encoder
    /// can spin up new sessions.
    private var pendingResizeRect: CGRect?
    private var resizeDebounceTimer: Timer?
    /// Quiet window after the last contentRect change before applying
    /// the resize. 200 ms is long enough to ride out a continuous drag
    /// without flickering the encoder; short enough that the viewer
    /// sees the new dims promptly when the user lets go.
    private static let resizeDebounceSeconds: TimeInterval = 0.2

    init(writer: HelperFrameWriter) {
        self.writer = writer
    }

    /// Bring the SCStream up against an `SCContentFilter` delivered
    /// by the parent over stdin. The filter retains XPC handles to
    /// system services it acquired in the picker subprocess; calling
    /// any other `SCContentFilter`/`SCShareableContent` API in this
    /// process before this point would invalidate them.
    func startWithFilter(
        _ filter: SCContentFilter, colorInfo: ColorInfo = .bt709FullRange8, captureAudio: Bool
    ) async {
        self.colorInfo = colorInfo
        if hasStarted {
            // A second start request is a parent-side bug. Refuse it
            // rather than racing two SCStreams against the same
            // helper's encoder state.
            writer.writeLog("capture-helper: ignored duplicate start request")
            return
        }
        hasStarted = true
        if captureAudio {
            // Build the tap and its audio-output hookup before the SCStream
            // comes up. The encode callback runs on the SCStream audio queue;
            // capture the writer + latch directly (both `Sendable`) so it never
            // hops to the MainActor — the same no-hop rationale as the heartbeat.
            let writer = self.writer
            let latch = self.audioEnabled
            do {
                let tap = try SystemAudioTap { au in
                    guard latch.withLock({ $0 }) else { return }
                    writer.writeAudioAccessUnit(au)
                }
                self.systemAudioTap = tap
                captureWrapper.capturesAudio = true
                captureWrapper.onAudioSampleBuffer = { [tap] sampleBuffer in
                    tap.handle(sampleBuffer)
                }
            } catch {
                writer.writeLog("capture-helper: system-audio tap init failed: \(error) — video only")
            }
        }
        captureWrapper.onFrameCaptured = { [weak self] pixelBuffer in
            Task { @MainActor [weak self] in self?.handleFrame(pixelBuffer) }
        }
        captureWrapper.onContentRectChanged = { [weak self] rect in
            Task { @MainActor [weak self] in self?.scheduleResize(to: rect) }
        }
        // Forward capture liveness as a heartbeat. Runs on the SCStream
        // delegate queue; write directly (the writer is thread-safe) with no
        // MainActor hop, so a busy main thread can't mask capture liveness.
        captureWrapper.onStreamSample = { [writer = self.writer] in
            writer.writeHeartbeat()
        }
        captureWrapper.onStreamStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Self.isUserStopped(error) {
                    self.writer.writeLog("SCStream stopped by user (Control Center)")
                    self.writer.writeUserStopped()
                    // Give the wire flush a moment, then exit cleanly.
                    try? await Task.sleep(for: .milliseconds(50))
                    exit(0)
                }
                self.writer.writeFatal("SCStream stopped: \(error?.localizedDescription ?? "nil")")
                exit(1)
            }
        }
        do {
            try await captureWrapper.start(filter: filter, fps: quality.fpsCap, colorInfo: colorInfo)
            writer.writeLog("capture-helper: SCStream up")
        } catch {
            writer.writeFatal("SCStream start failed: \(error)")
            exit(2)
        }
    }

    func shutdown() async {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = nil
        pendingResizeRect = nil
        encoder?.shutdown()
        encoder = nil
        systemAudioTap = nil
        await captureWrapper.stop()
    }

    /// Toggle system-audio emission. The audio SCStream output stays up; this
    /// just flips whether the tap forwards encoded AUs, so mute/unmute is
    /// instant. No-op when the share started without audio capture.
    func setAudioEnabled(_ on: Bool) async {
        audioEnabled.withLock { $0 = on }
    }

    /// Coalesce per-frame contentRect updates from SCStream into one
    /// pending resize; reset the debounce timer each tick so the apply
    /// only fires once the user stops dragging. Sized in points; the
    /// applier multiplies by the filter's `pointPixelScale` for pixel
    /// dims.
    private func scheduleResize(to rect: CGRect) {
        pendingResizeRect = rect
        resizeDebounceTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.resizeDebounceSeconds, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPendingResize()
            }
        }
        resizeDebounceTimer = timer
    }

    private func applyPendingResize() {
        guard let rect = pendingResizeRect else { return }
        pendingResizeRect = nil
        resizeDebounceTimer = nil
        let scale = CGFloat(captureWrapper.pointPixelScale)
        let pxWidth = max(2, Int((rect.width * scale).rounded()))
        let pxHeight = max(2, Int((rect.height * scale).rounded()))
        writer.writeLog(
            "capture-helper: applying resize -> \(pxWidth)x\(pxHeight)px (rect=\(Int(rect.width))x\(Int(rect.height))pt scale=\(scale))"
        )
        Task { @MainActor [weak self] in
            await self?.captureWrapper.updateConfiguration(
                pixelWidth: pxWidth, pixelHeight: pxHeight)
        }
    }

    func requestKeyframe() async {
        encoder?.requestKeyframe()
    }

    func setBitrate(_ bps: Int) async {
        guard bps > 0 else { return }
        encoder?.setBitrate(bps)
    }

    /// Apply an fps-ladder step from the server's congestion controller by
    /// retuning the SCStream's `minimumFrameInterval`. The encoder keeps its
    /// configured parameters; a lower delivery rate simply feeds it fewer
    /// frames (the primary rate lever). Runs in the helper — never the main
    /// process — per CLAUDE.md.
    func setFrameInterval(_ fps: Int) async {
        guard fps > 0 else { return }
        await captureWrapper.updateFrameInterval(fps: fps)
    }

    private var frameCounter: UInt64 = 0
    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])
    private let previewMaxWidth: CGFloat = 280

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCounter &+= 1
        // Downsample + JPEG-encode every ~half-second worth of frames
        // for the SharingCard thumbnail. Skipping to a low rate keeps
        // the pipe traffic dominated by the actual H.264/HEVC AUs.
        if frameCounter == 1 || frameCounter % 30 == 0 {
            if let jpeg = buildPreviewJPEG(from: pixelBuffer) {
                writer.writePreviewJPEG(jpeg)
            }
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Log each unique frame size we see. SCStream pins the buffer
        // dims to the configured width/height at start; when the shared
        // window resizes the SCContentFilter's contentRect changes but
        // the buffer dims do not, so a steady stream of unchanged dims
        // here while the user is resizing means we'd need
        // `stream.updateConfiguration` (not currently wired up) to
        // follow the window.
        if width != lastWidth || height != lastHeight {
            writer.writeLog(
                "capture-helper: frame dims \(lastWidth)x\(lastHeight) -> \(width)x\(height) (frame #\(frameCounter))"
            )
        } else if frameCounter == 1 || frameCounter % 300 == 0 {
            writer.writeLog(
                "capture-helper: frame dims steady \(width)x\(height) (frame #\(frameCounter))")
        }

        if encoder == nil || width != lastWidth || height != lastHeight {
            encoder?.shutdown()
            let newEncoder = VideoEncoder()
            do {
                // The parent sets TAILSCREEN_FORCE_H264=1 when a viewer
                // reported it can't decode HEVC; it overrides the user's
                // codec preference so the whole share falls back to the
                // universally-decodable codec.
                let forceH264 = ProcessInfo.processInfo.environment["TAILSCREEN_FORCE_H264"] == "1"
                let preferred = quality.preferredVideoCodec(forceH264: forceH264)
                newEncoder.encoderQuality = quality.encoderQuality
                // Tag the encoder with the captured color (BT.709 / P3 /
                // BT.2020) + bit depth; the encoder's fallback ladder drops
                // 10-bit → 8-bit and HEVC → H.264 if VideoToolbox refuses.
                newEncoder.colorInfo = colorInfo
                try newEncoder.setup(
                    width: width, height: height, fps: Int32(quality.fpsCap), preferredCodec: preferred)
                let codec = newEncoder.codec
                // If the user capped bandwidth, tighten the encoder's
                // DataRateLimits ceiling below the bits-per-pixel formula
                // it was set up with. Uses the shared
                // `VideoEncoder.computeBitrate` — the server's adaptive
                // sweep anchors its baseline to the same min() over the
                // same formula, so the two stay coherent.
                if let ceiling = quality.maxBitrateBps {
                    let bpp = VideoEncoder.defaultBitsPerPixel(for: codec)
                    let computed = VideoEncoder.computeBitrate(
                        width: width, height: height, fps: quality.fpsCap, bitsPerPixel: bpp)
                    if ceiling < computed {
                        newEncoder.setBitrate(ceiling)
                    }
                }
                writer.writeLog("capture-helper: encoder \(codec) \(width)x\(height) @\(quality.fpsCap)fps")
                lastWidth = width
                lastHeight = height
                // Capture `writer` directly so the callback writes
                // synchronously from the encoder's serial output thread.
                // VideoEncoder fires onParameterSets THEN onEncodedData
                // back-to-back for keyframes; routing through
                // `Task @MainActor` reorders them and main ends up
                // broadcasting an AVCC AU before SPS/PPS arrive,
                // which the viewer's decoder can't decode → black
                // screen. Writing inline preserves the order.
                let w = writer
                let firstFrameFlag = FirstFrameFlag()
                newEncoder.onParameterSets = { params in
                    Self.writeParameterSets(w, params: params, width: width, height: height)
                }
                newEncoder.onEncodedData = { data, isKeyframe in
                    if firstFrameFlag.markIfFirst() {
                        w.writeFirstFrame()
                    }
                    w.writeAccessUnit(data, containsKeyframe: isKeyframe)
                }
                encoder = newEncoder
            } catch {
                writer.writeFatal("encoder setup failed: \(error)")
                return
            }
        }

        encoder?.encode(pixelBuffer: pixelBuffer)
    }

    /// One-shot atomic flag for "have we written the firstFrame
    /// signal yet". Touched only from the encoder's serial output
    /// thread, but `@unchecked Sendable` lets the runner construct
    /// it on @MainActor and hand it across.
    final class FirstFrameFlag: @unchecked Sendable {
        private var sent = false
        func markIfFirst() -> Bool {
            if sent { return false }
            sent = true
            return true
        }
    }

    /// Downsample the captured CVPixelBuffer to ~280 px wide and
    /// encode JPEG bytes for the SharingCard thumbnail. Emits raw
    /// JPEG (rather than `NSImage`) because the wire protocol only
    /// carries bytes — the parent reconstructs an `NSImage` on the
    /// other side via `HelperScreenCapture.onPreviewImage`.
    private func buildPreviewJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let srcExtent = ciImage.extent
        guard srcExtent.width > 0 else { return nil }
        let scale = min(1.0, previewMaxWidth / srcExtent.width)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = previewContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
    }

    /// True when SCStream's `didStopWithError` payload is the
    /// `userStopped` Control Center signal (vs. replayd's many
    /// internal-error variants).
    static func isUserStopped(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsErr = error as NSError
        return nsErr.domain == SCStreamError.errorDomain
            && nsErr.code == SCStreamError.Code.userStopped.rawValue
    }

    nonisolated static func writeParameterSets(
        _ writer: HelperFrameWriter, params: CodecParameterSets, width: Int, height: Int
    ) {
        let codecByte: UInt8
        var paramSets: [Data] = []
        switch params {
        case .h264(let sps, let pps):
            codecByte = 0
            paramSets = [sps, pps]
        case .hevc(let vps, let sps, let pps):
            codecByte = 1
            paramSets = [vps, sps, pps]
        }
        writer.writeParameterSets(codec: codecByte, width: width, height: height, paramSets: paramSets)
    }

}
