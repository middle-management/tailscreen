import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
// `@preconcurrency`: SCShareableContent isn't Sendable; the cross-actor hand-off
// to @MainActor below is safe (used once on the same actor) but unaudited.
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import os

/// Entry point for `Tailscreen --capture-helper`. Owns the SCStream +
/// VideoEncoder pipeline; pipes encoded access units to the main process via
/// stdout, reads control messages on stdin. Exits on `shutdown`, SCStream's
/// `didStopWithError` (replayd dropped us), or SIGTERM/SIGINT.
enum CaptureHelperMain {
    static func run() -> Never {
        // Redirect FD 1 -> stderr so stray prints don't corrupt the binary
        // frame protocol; the frame writer keeps the saved FD 1.
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
            // Startup watchdog: if the parent never delivers a `contentFilter`
            // frame, bail with `permanent:` rather than sitting on the run
            // loop forever, so the crash-budget loop doesn't keep respawning
            // into the same wedge.
            try? await Task.sleep(for: .seconds(10))
            if !runner.hasStarted {
                writer.writeFatal(
                    "permanent: parent never delivered contentFilter within 10s")
                exit(3)
            }
        }
        RunLoop.main.run()
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
        Self.signalSources = [sigSrc, sigInt]  // held for process lifetime
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
                    // `SCShareableContent` is only legal here, never in the
                    // main process. Must land on @MainActor for the SCStream
                    // + VideoToolbox setup sequence.
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
                            // Captured window/display/app no longer resolves
                            // (user closed it) — expected stop, not an error.
                            writer.writeFatal("source-gone: \(error)")
                            exit(3)
                        } catch {
                            // `permanent:` tells the server's crash-restart
                            // budget not to retry — respawning hits the same error.
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

    /// Reconstruct an `SCContentFilter` from the primitives the picker-helper
    /// extracted, resolving IDs via `SCShareableContent` — legal only here,
    /// not the main process.
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
            // Cloaked Apps: excluded by application, so new windows of a
            // resolved app stay hidden without a filter rebuild. A cloaked app
            // not yet running can't resolve here — `AppState`'s NSWorkspace
            // observer re-pushes the filter on its launch.
            let cloakedSet = Set(selection.excludedBundleIDs)
            guard !cloakedSet.isEmpty else {
                return SCContentFilter(display: display, excludingWindows: [])
            }
            let cloakedApps = content.applications.filter {
                cloakedSet.contains($0.bundleIdentifier)
            }
            return SCContentFilter(
                display: display, excludingApplications: cloakedApps, exceptingWindows: [])
        case .window:
            guard let id = selection.windowID,
                let window = content.windows.first(where: { $0.windowID == id })
            else {
                throw PickerReconstructionError.windowNotFound(selection.windowID)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .application:
            // SCContentFilter's "share these apps" constructor is anchored to
            // a display; fall back to the main one if the picker omitted it.
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

    /// Display P3 8-bit tagging is on by default for wide-gamut displays;
    /// 10-bit HEVC Main 10 / HDR (BT.2020 PQ) are opt-in via
    /// `TAILSCREEN_ENABLE_10BIT`/`TAILSCREEN_ENABLE_HDR`, gated on display
    /// capability. `TAILSCREEN_FORCE_8BIT`/`TAILSCREEN_FORCE_H264` both pin 8-bit.
    @MainActor
    static func captureColorInfo(for selection: PickerSelection, env: [String: String]) -> ColorInfo {
        let forceH264 = env["TAILSCREEN_FORCE_H264"] == "1"
        let force8bit = env["TAILSCREEN_FORCE_8BIT"] == "1"
        let enable10bit = env["TAILSCREEN_ENABLE_10BIT"] == "1"
        let enableHDR = env["TAILSCREEN_ENABLE_HDR"] == "1"
        let displayID = selection.displayID ?? CGMainDisplayID()
        let wideGamut = displayIsWideGamut(displayID)
        let hdrCapable = enableHDR && displayIsHDR(displayID)
        // 10-bit is HEVC-only; a viewer's 8-bit request overrides.
        let want10 = (enable10bit || hdrCapable) && !forceH264 && !force8bit
        let bitDepth = want10 ? 10 : 8
        return ColorInfo.forDisplay(wideGamut: wideGamut, hdrCapable: hdrCapable, bitDepth: bitDepth)
    }

    /// True when the display renders wider than sRGB (P3 or better). Safe on
    /// any thread.
    static func displayIsWideGamut(_ displayID: CGDirectDisplayID) -> Bool {
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        return colorSpace.isWideGamutRGB
    }

    /// True when the display advertises EDR headroom above SDR. Must run on
    /// the main thread (`NSScreen`).
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

/// SCStream + VideoEncoder lifecycle inside the helper. Encoded access units
/// go to the framed wire on stdout instead of fanning out as RTP.
@MainActor
private final class CaptureHelperRunner {
    private let writer: HelperFrameWriter
    private let captureWrapper = ScreenCapture()
    private var encoder: VideoEncoder?
    /// System-audio pipeline (CMSampleBuffer → Opus AU), created only when the
    /// selection asked for audio capture.
    private var systemAudioTap: SystemAudioTap?
    /// Emission latch toggled by the `setAudioEnabled` wire message. Locked:
    /// the tap's encode callback (SCStream audio queue) reads it while the
    /// stdin reader writes it.
    private let audioEnabled = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Spawn-time quality knobs from `QualitySettings.helperEnvironment()`.
    /// Read once — live ceiling changes ride the `setBitrate` wire message.
    private let quality = QualitySettings.fromEnvironment(ProcessInfo.processInfo.environment)
    /// Color characteristics for this share, threaded into both the SCStream
    /// config and the encoder so capture and encode agree.
    private var colorInfo: ColorInfo = .bt709FullRange8
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    /// Read by the startup watchdog in `CaptureHelperMain.run()`.
    fileprivate var hasStarted = false

    /// Pending contentRect (points), coalesced by `resizeDebounceTimer` so a
    /// 60Hz live drag becomes one `updateConfiguration` per ~200ms instead of
    /// per frame — SCStream thrashes if reconfigured faster than the encoder
    /// can spin up new sessions.
    private var pendingResizeRect: CGRect?
    private var resizeDebounceTimer: Timer?
    private static let resizeDebounceSeconds: TimeInterval = 0.2

    init(writer: HelperFrameWriter) {
        self.writer = writer
    }

    /// Bring the SCStream up against a filter delivered over stdin. It
    /// retains XPC handles from the picker subprocess; calling any other
    /// `SCContentFilter`/`SCShareableContent` API here first would invalidate them.
    func startWithFilter(
        _ filter: SCContentFilter, colorInfo: ColorInfo = .bt709FullRange8, captureAudio: Bool
    ) async {
        self.colorInfo = colorInfo
        if hasStarted {
            // A second start request is a parent-side bug; refuse rather than
            // racing two SCStreams against the same encoder state.
            writer.writeLog("capture-helper: ignored duplicate start request")
            return
        }
        hasStarted = true
        if captureAudio {
            // Capture writer + latch directly (both Sendable) so the encode
            // callback (SCStream audio queue) never hops to MainActor.
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
        // Write directly, no MainActor hop, so a busy main thread can't mask
        // capture liveness.
        captureWrapper.onStreamSample = { [writer = self.writer] in
            writer.writeHeartbeat()
        }
        captureWrapper.onStreamStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Self.isUserStopped(error) {
                    self.writer.writeLog("SCStream stopped by user (Control Center)")
                    self.writer.writeUserStopped()
                    try? await Task.sleep(for: .milliseconds(50))  // let the wire flush
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

    /// Flips whether the tap forwards encoded AUs (mute/unmute); the audio
    /// SCStream output itself stays up.
    func setAudioEnabled(_ on: Bool) async {
        audioEnabled.withLock { $0 = on }
    }

    /// Coalesce per-frame contentRect updates; resets the debounce timer each
    /// tick so the apply fires only once dragging stops.
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

    /// Applies an fps-ladder step by retuning the SCStream's
    /// `minimumFrameInterval`; the encoder's own config is unchanged.
    func setFrameInterval(_ fps: Int) async {
        guard fps > 0 else { return }
        await captureWrapper.updateFrameInterval(fps: fps)
    }

    private var frameCounter: UInt64 = 0
    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])
    private let previewMaxWidth: CGFloat = 280

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCounter &+= 1
        // ~Every half-second, for the SharingCard thumbnail; keeps pipe
        // traffic dominated by the actual AUs.
        if frameCounter == 1 || frameCounter % 30 == 0 {
            if let jpeg = buildPreviewJPEG(from: pixelBuffer) {
                writer.writePreviewJPEG(jpeg)
            }
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

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
                // TAILSCREEN_FORCE_H264=1 means a viewer can't decode HEVC;
                // it overrides the user's codec preference for the whole share.
                let forceH264 = ProcessInfo.processInfo.environment["TAILSCREEN_FORCE_H264"] == "1"
                let preferred = quality.preferredVideoCodec(forceH264: forceH264)
                newEncoder.encoderQuality = quality.encoderQuality
                // Explicit HEVC preference means no H.264 fallback rung: fail
                // rather than silently downgrade. Moot when forceH264 already won.
                newEncoder.allowsH264Fallback = quality.codecPreference != .hevc
                // The fallback ladder drops 10-bit -> 8-bit and HEVC -> H.264
                // if VideoToolbox refuses.
                newEncoder.colorInfo = colorInfo
                try newEncoder.setup(
                    width: width, height: height, fps: Int32(quality.fpsCap), preferredCodec: preferred)
                let codec = newEncoder.codec
                // Uses the same `computeBitrate`/`cappedBitrate` the server's
                // adaptive sweep anchors to, so the two stay coherent.
                let bpp = VideoEncoder.defaultBitsPerPixel(for: codec)
                let computed = VideoEncoder.computeBitrate(
                    width: width, height: height, fps: quality.fpsCap, bitsPerPixel: bpp)
                let capped = quality.cappedBitrate(anchorBps: computed)
                if capped < computed {
                    newEncoder.setBitrate(capped)
                }
                writer.writeLog("capture-helper: encoder \(codec) \(width)x\(height) @\(quality.fpsCap)fps")
                lastWidth = width
                lastHeight = height
                // Write inline (not `Task @MainActor`): onParameterSets fires
                // before onEncodedData for keyframes, and hopping actors can
                // reorder them, sending an AVCC AU before SPS/PPS -> black screen.
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

    /// One-shot flag; touched only from the encoder's serial output thread,
    /// but `@unchecked Sendable` lets the runner construct it on @MainActor
    /// and hand it across.
    final class FirstFrameFlag: @unchecked Sendable {
        private var sent = false
        func markIfFirst() -> Bool {
            if sent { return false }
            sent = true
            return true
        }
    }

    /// Raw JPEG bytes (the wire only carries bytes); the parent reconstructs
    /// an `NSImage` via `HelperScreenCapture.onPreviewImage`.
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

    /// True for the `userStopped` Control Center signal, vs. replayd's
    /// internal-error variants.
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
