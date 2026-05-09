import Foundation
import ScreenCaptureKit
import AppKit
import CoreMedia
import CoreVideo

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
              let displayID = UInt32(displayIDString) else {
            fputs("capture-helper: --display <id> required\n", stderr)
            exit(64)
        }

        // Move our binary frame protocol off FD 1 onto FD 4. ScreenCapture
        // and friends call `print()` freely, which writes to FD 1; if FD 1
        // were our framed-protocol channel, every print would corrupt the
        // stream. Redirect FD 1 → stderr (FD 2) so prints flow to the
        // helper's stderr (which the main process inherits), and put the
        // framed protocol on FD 4 (which main attaches via a Pipe).
        let frameFD: Int32 = 4
        // Sanity: if FD 4 isn't open (e.g. running from a shell with no
        // explicit redirect), fall back to FD 1 with a stderr-only mode.
        var st = stat()
        let frameAvailable = fstat(frameFD, &st) == 0
        let outFD: Int32 = frameAvailable ? frameFD : 1
        if frameAvailable {
            // Redirect Swift print()/FD1 to stderr so they don't pollute
            // our binary protocol on FD 4.
            _ = dup2(2, 1)
        }
        let writer = HelperFrameWriter(handle: FileHandle(fileDescriptor: outFD, closeOnDealloc: false))
        writer.writeLog("capture-helper: starting for displayID=\(displayID) frameFD=\(outFD)")

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
            Task { await runner.shutdown(); exit(0) }
        }
        signal(SIGTERM, SIG_IGN)
        sigSrc.resume()
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigInt.setEventHandler {
            writer.writeLog("capture-helper: SIGINT, shutting down")
            Task { await runner.shutdown(); exit(0) }
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
                    Task { await runner.shutdown(); exit(0) }
                }
            }
            writer.writeLog("capture-helper: stdin closed, exiting")
            Task { await runner.shutdown(); exit(0) }
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    private static func argValue(_ args: [String], _ flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

private extension Data {
    func readBE32() -> UInt32? {
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

/// SCStream + VideoEncoder lifecycle inside the helper. Mirrors the
/// shape of `TailscaleScreenShareServer.handleCapturedFrame` but
/// streams output to stdout instead of fanning out RTP.
@MainActor
private final class CaptureHelperRunner {
    private let displayID: CGDirectDisplayID
    private let writer: HelperFrameWriter
    private let captureWrapper = ScreenCapture()
    private var encoder: VideoEncoder?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var firstFrameSent = false

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
                self?.writer.writeFatal("SCStream stopped: \(error?.localizedDescription ?? "nil")")
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

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
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
                newEncoder.onParameterSets = { [weak self] params in
                    Task { @MainActor [weak self] in self?.emitParameterSets(params, width: width, height: height) }
                }
                newEncoder.onEncodedData = { [weak self] data, isKeyframe in
                    Task { @MainActor [weak self] in self?.emitAccessUnit(data, isKeyframe: isKeyframe) }
                }
                encoder = newEncoder
            } catch {
                writer.writeFatal("encoder setup failed: \(error)")
                return
            }
        }

        encoder?.encode(pixelBuffer: pixelBuffer)
    }

    private func emitParameterSets(_ params: CodecParameterSets, width: Int, height: Int) {
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

    private func emitAccessUnit(_ data: Data, isKeyframe: Bool) {
        if !firstFrameSent {
            firstFrameSent = true
            writer.writeFirstFrame()
        }
        writer.writeAccessUnit(data, containsKeyframe: isKeyframe)
    }
}
