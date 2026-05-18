import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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
        // Argument parsing. Required: --display <id>
        let args = CommandLine.arguments
        guard let displayIDString = argValue(args, "--display"),
            let displayID = UInt32(displayIDString)
        else {
            fputs("capture-helper: --display <id> required\n", stderr)
            exit(64)
        }

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
        writer.writeLog("capture-helper: starting for displayID=\(displayID) frameFD=\(frameFD)")

        Task { @MainActor in
            let runner = CaptureHelperRunner(displayID: CGDirectDisplayID(displayID), writer: writer)
            installSignalHandlers(writer: writer, runner: runner)
            installStdinReader(writer: writer, runner: runner)
            await runner.start()
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

    private static func argValue(_ args: [String], _ flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
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
    private let displayID: CGDirectDisplayID
    private let writer: HelperFrameWriter
    private let captureWrapper = ScreenCapture()
    private var encoder: VideoEncoder?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    init(displayID: CGDirectDisplayID, writer: HelperFrameWriter) {
        self.displayID = displayID
        self.writer = writer
    }

    func start() async {
        captureWrapper.onFrameCaptured = { [weak self] pixelBuffer in
            Task { @MainActor [weak self] in self?.handleFrame(pixelBuffer) }
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
            try await captureWrapper.start(displayID: displayID)
            writer.writeLog("capture-helper: SCStream up")
        } catch {
            writer.writeFatal("SCStream start failed: \(error)")
            exit(2)
        }
    }

    func shutdown() async {
        encoder?.shutdown()
        encoder = nil
        await captureWrapper.stop()
    }

    func requestKeyframe() async {
        encoder?.requestKeyframe()
    }

    func setBitrate(_ bps: Int) async {
        guard bps > 0 else { return }
        encoder?.setBitrate(bps)
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

        if encoder == nil || width != lastWidth || height != lastHeight {
            encoder?.shutdown()
            let newEncoder = VideoEncoder()
            do {
                try newEncoder.setup(width: width, height: height, fps: 60)
                let codec = newEncoder.codec
                writer.writeLog("capture-helper: encoder \(codec) \(width)x\(height) @60fps")
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
