import Foundation
import AppKit
import CoreGraphics

/// Main-side wrapper around the `Tailscreen --capture-helper` child
/// process. Spawns a fresh helper per share session, parses framed
/// access units off its stdout, and surfaces them through callbacks
/// shaped like the in-process `ScreenCapture` so the rest of the
/// server doesn't have to care which path produced the bytes.
///
/// Why a child process: macOS's `replayd` is the only process that
/// can definitively release a per-bundle SCStream slot, and the
/// only signal it always responds to is process death. Killing the
/// child on Stop Sharing reliably clears the recording badge and the
/// "interrupted/orphan" state that has wedged Tailscreen across
/// session boundaries (Apple bug FB16310901).
final class HelperScreenCapture: @unchecked Sendable {
    /// Helper produced an encoded access unit. `(avccData, isKeyframe)`.
    /// Mirrors `VideoEncoder.onEncodedData` so the server can broadcast
    /// without an in-process encoder.
    var onAccessUnit: ((Data, Bool) -> Void)?
    /// Codec parameter sets, sent once per encoder configuration.
    var onParameterSets: ((CodecParameterSets) -> Void)?
    /// Encoded resolution, surfaced once per parameter-sets emit so
    /// the server can anchor its adaptive-bitrate baseline.
    var onEncoderResolution: ((Int, Int) -> Void)?
    /// Fires the first time the helper's encoder produces a frame —
    /// signal for the SharingCard's "first preview" gate.
    var onFirstFrame: (() -> Void)?
    /// Helper sent a downsampled preview JPEG for the SharingCard
    /// thumbnail. ~1 Hz cadence.
    var onPreviewImage: ((NSImage) -> Void)?
    /// Fires when the helper exits unexpectedly (process death without
    /// a prior `stop()` call). The reason describes how it died.
    var onUnexpectedExit: ((String) -> Void)?
    /// Fires when the helper reports the user clicked the macOS
    /// Control Center "Stop" button. Distinct from `onUnexpectedExit`
    /// so the server tears the share down instead of respawning.
    var onUserStopped: (() -> Void)?

    private let queueLabel: String
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readerThread: Thread?
    private var stoppedIntentionally = false
    private var debugAUCount = 0
    private var debugParamsLogged = false

    init() {
        queueLabel = "HelperScreenCapture-\(UUID().uuidString.prefix(8))"
    }

    func start(displayID: CGDirectDisplayID) throws {
        guard let exe = Bundle.main.executableURL else {
            throw HelperScreenCaptureError.executableNotFound
        }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--capture-helper", "--display", "\(displayID)"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Inherit stderr so helper logs land in the merged log alongside
        // ours — easier debugging.

        proc.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if !self.stoppedIntentionally {
                let reason: String
                switch proc.terminationReason {
                case .exit:
                    reason = "exit code \(proc.terminationStatus)"
                case .uncaughtSignal:
                    reason = "signal \(proc.terminationStatus)"
                @unknown default:
                    reason = "unknown termination"
                }
                self.onUnexpectedExit?(reason)
            }
        }

        try proc.run()
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading

        // Reader thread — synchronous reads on the pipe. Async
        // FileHandle reads on a Pipe-backed handle are buggy in some
        // Swift releases; a dedicated thread doing blocking reads is
        // simpler and more reliable.
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = queueLabel
        thread.start()
        readerThread = thread
    }

    /// Send a framed shutdown to the helper, give it a moment to
    /// drain, then SIGTERM, then SIGKILL. Returns once we've torn the
    /// process down — process death = replayd cleanup.
    func stop() async {
        stoppedIntentionally = true
        guard let proc = process else { return }
        // Best-effort graceful shutdown.
        if let stdin = stdinHandle {
            let writer = HelperControlWriter(handle: stdin)
            writer.sendShutdown()
            try? stdin.close()
        }
        // Give the helper ~500 ms to clean up before SIGTERM.
        try? await Task.sleep(for: .milliseconds(500))
        if proc.isRunning {
            proc.terminate()
        }
        // SIGKILL after another 1 s if SIGTERM was ignored.
        for _ in 0..<10 {
            if !proc.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        readerThread = nil
    }

    func requestKeyframe() {
        guard let stdin = stdinHandle else { return }
        HelperControlWriter(handle: stdin).sendKeyframeRequest()
    }

    func setBitrate(_ bps: Int) {
        guard let stdin = stdinHandle else { return }
        HelperControlWriter(handle: stdin).sendBitrate(bps)
    }

    private func readLoop() {
        guard let handle = stdoutHandle else { return }
        let reader = HelperFrameReader(handle: handle)
        while let (rawType, payload) = reader.readNext() {
            guard let type = CaptureHelperWire.OutType(rawValue: rawType) else {
                // Unknown type — log and resync (next 5-byte header).
                continue
            }
            switch type {
            case .accessUnit:
                guard payload.count >= 1 else { continue }
                let isKeyframe = payload[payload.startIndex] != 0
                let avcc = Data(payload[payload.index(after: payload.startIndex)...])
                debugAUCount += 1
                if debugAUCount <= 3 {
                    let first = avcc.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("HelperScreenCapture: AU#\(debugAUCount) kf=\(isKeyframe) \(avcc.count)B first8=[\(first)]")
                }
                onAccessUnit?(avcc, isKeyframe)
            case .parameterSets:
                if payload.count >= 9 {
                    let w = Int(readBE32(payload, offset: 1))
                    let h = Int(readBE32(payload, offset: 5))
                    if w > 0 && h > 0 {
                        onEncoderResolution?(w, h)
                    }
                }
                if let params = decodeParameterSets(payload) {
                    if !debugParamsLogged {
                        debugParamsLogged = true
                        switch params {
                        case .h264(let sps, let pps):
                            print("HelperScreenCapture: paramSets H264 sps=\(sps.count)B pps=\(pps.count)B")
                        case .hevc(let vps, let sps, let pps):
                            print("HelperScreenCapture: paramSets HEVC vps=\(vps.count)B sps=\(sps.count)B pps=\(pps.count)B")
                        }
                    }
                    onParameterSets?(params)
                }
            case .firstFrame:
                onFirstFrame?()
            case .previewJPEG:
                if let img = NSImage(data: payload) {
                    onPreviewImage?(img)
                }
            case .logLine:
                if let s = String(data: payload, encoding: .utf8) {
                    print("helper: \(s)")
                }
            case .fatal:
                let msg = String(data: payload, encoding: .utf8) ?? "<no msg>"
                stoppedIntentionally = true  // helper is exiting on purpose
                onUnexpectedExit?("fatal: \(msg)")
                return
            case .userStopped:
                stoppedIntentionally = true
                onUserStopped?()
                return
            }
        }
    }

    private func decodeParameterSets(_ data: Data) -> CodecParameterSets? {
        // Layout: [codec:1][width:4 BE][height:4 BE][count:4 BE]([len:4 BE][data:N])*
        guard data.count >= 13 else { return nil }
        let codec = data[0]
        // width/height are informational only; CodecParameterSets carries
        // just the NAL byte arrays.
        let count = readBE32(data, offset: 9)
        var cursor = 13
        var paramSets: [Data] = []
        for _ in 0..<count {
            guard cursor + 4 <= data.count else { return nil }
            let len = Int(readBE32(data, offset: cursor))
            cursor += 4
            guard cursor + len <= data.count else { return nil }
            paramSets.append(data.subdata(in: cursor..<cursor + len))
            cursor += len
        }
        switch codec {
        case 0:
            guard paramSets.count >= 2 else { return nil }
            return .h264(sps: paramSets[0], pps: paramSets[1])
        case 1:
            guard paramSets.count >= 3 else { return nil }
            return .hevc(vps: paramSets[0], sps: paramSets[1], pps: paramSets[2])
        default:
            return nil
        }
    }

    private func readBE32(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

enum HelperScreenCaptureError: Error {
    case executableNotFound
}
