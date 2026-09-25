import Foundation
import TailscaleKit
import os

/// Main-side wrapper around the `Tailscreen --capture-helper` child process.
/// Spawns a fresh helper per share, parses framed access units off its
/// stdout, and surfaces them through callbacks shaped like `ScreenCapture`.
///
/// A child process because `replayd` releases a per-bundle SCStream slot only
/// on process death — killing the child on Stop Sharing reliably clears the
/// recording badge and orphan state that has wedged sharing across sessions
/// (Apple bug FB16310901).
final class HelperScreenCapture: @unchecked Sendable {
    /// `(avccData, isKeyframe)`. Mirrors `VideoEncoder.onEncodedData` so the
    /// server broadcasts without an in-process encoder.
    var onAccessUnit: ((Data, Bool) -> Void)?
    /// Raw Opus packet bytes; the server packetizes as RTP PT 99.
    var onAudioAccessUnit: ((Data) -> Void)?
    var onParameterSets: ((CodecParameterSets) -> Void)?
    /// Surfaced once per parameter-sets emit so the server can anchor its
    /// adaptive-bitrate baseline.
    var onEncoderResolution: ((Int, Int) -> Void)?
    /// First frame from the helper's encoder — SharingCard's "first preview" gate.
    var onFirstFrame: (() -> Void)?
    /// Encoded JPEG bytes (not a decoded image — `CaptureEncoding` is
    /// Foundation-only; decode happens at `AppState.previewImage`), ~1Hz.
    var onPreviewImage: ((Data) -> Void)?
    /// Process death without a prior `stop()` call.
    var onUnexpectedExit: ((String) -> Void)?
    /// User clicked Control Center's "Stop" — distinct from `onUnexpectedExit`
    /// so the server tears down instead of respawning.
    var onUserStopped: (() -> Void)?
    /// Fires on every message from the helper; feeds the hung-helper watchdog,
    /// since a wedged-but-alive SCStream stops producing without exiting.
    var onActivity: (() -> Void)?

    /// Pushed by `AppState` from Settings -> Color and merged into every
    /// helper's environment. Static because the crash-restart path constructs
    /// `HelperScreenCapture` deep inside TailscreenSharer, which knows nothing
    /// about macOS settings. Locked: written on MainActor, read on the spawn
    /// thread. Merged before `qualityEnv` so a server override (e.g.
    /// `TAILSCREEN_FORCE_8BIT`) keeps the last word.
    static let colorEnvironment = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private let queueLabel: String
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readerThread: Thread?
    /// Set on deliberate exit (`stop()`, `fatal`/`userStopped`) so
    /// `terminationHandler` doesn't misread it as a crash. Locked: written
    /// from `stop()`/reader thread, read from the process's arbitrary
    /// termination-handler queue.
    private let stoppedIntentionally = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var debugAUCount = 0
    private var debugParamsLogged = false
    private let logger = TSLogger()

    init() {
        queueLabel = "HelperScreenCapture-\(UUID().uuidString.prefix(8))"
    }

    /// - Parameters:
    ///   - forceH264: codec-fallback path when a viewer can't decode HEVC;
    ///     wins over any `qualityEnv` codec preference.
    ///   - qualityEnv: spawn-time quality knobs from `QualitySettings.helperEnvironment()`.
    func start(selectionData: Data, forceH264: Bool = false, qualityEnv: [String: String] = [:]) throws {
        guard let exe = resolveHelperExecutable() else {
            throw HelperScreenCaptureError.executableNotFound
        }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--capture-helper"]
        let colorEnv = Self.colorEnvironment.withLock { $0 }
        if forceH264 || !qualityEnv.isEmpty || !colorEnv.isEmpty {
            // `environment` replaces, not merges — seed from ours first, since
            // the helper relies on inherited vars (TAILSCREEN_INSTANCE, TS
            // auth keys, etc.).
            var env = ProcessInfo.processInfo.environment
            env.merge(colorEnv) { _, override in override }
            env.merge(qualityEnv) { _, override in override }
            if forceH264 {
                env["TAILSCREEN_FORCE_H264"] = "1"
            }
            proc.environment = env
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Inherit stderr so helper logs land in the merged log.

        proc.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if !self.stoppedIntentionally.withLock({ $0 }) {
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

        if let stdin = stdinHandle {
            HelperControlWriter(handle: stdin).sendContentFilter(selectionData)
        }

        // Dedicated thread doing blocking reads: async FileHandle reads on a
        // Pipe-backed handle are buggy in some Swift releases.
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = queueLabel
        thread.start()
        readerThread = thread
    }

    /// Framed shutdown, then SIGTERM, then SIGKILL — process death triggers
    /// replayd cleanup.
    func stop() async {
        stoppedIntentionally.withLock { $0 = true }
        guard let proc = process else { return }
        if let stdin = stdinHandle {
            let writer = HelperControlWriter(handle: stdin)
            writer.sendShutdown()
            try? stdin.close()
        }
        try? await Task.sleep(for: .milliseconds(500))
        if proc.isRunning {
            proc.terminate()
        }
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

    /// No-op if the helper isn't up yet — the server re-sends after every spawn.
    func setAudioEnabled(_ on: Bool) {
        guard let stdin = stdinHandle else { return }
        HelperControlWriter(handle: stdin).sendAudioEnabled(on)
    }

    func setFrameInterval(_ fps: Int) {
        guard let stdin = stdinHandle else { return }
        HelperControlWriter(handle: stdin).sendFrameInterval(fps)
    }

    private func readLoop() {
        guard let handle = stdoutHandle else { return }
        let reader = HelperFrameReader(handle: handle)
        while let (rawType, payload) = reader.readNext() {
            // Any byte is proof of life for the watchdog, not just the heartbeat.
            onActivity?()
            guard let type = CaptureHelperWire.OutType(rawValue: rawType) else {
                continue  // unknown type: resync at the next 5-byte header
            }
            switch type {
            case .accessUnit:
                guard payload.count >= 1 else { continue }
                let isKeyframe = payload[payload.startIndex] != 0
                let avcc = Data(payload[payload.index(after: payload.startIndex)...])
                debugAUCount += 1
                if debugAUCount <= 3 {
                    let first = avcc.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                    logger.log(
                        "HelperScreenCapture: AU#\(debugAUCount) kf=\(isKeyframe) \(avcc.count)B first8=[\(first)]")
                }
                onAccessUnit?(avcc, isKeyframe)
            case .audioAccessUnit:
                guard !payload.isEmpty else { continue }
                onAudioAccessUnit?(payload)
            case .parameterSets:
                // Must fire onParameterSets before onEncoderResolution: the
                // server's resolution handler reads the codec that
                // onParameterSets caches, to pick the bpp for its
                // adaptive-bitrate anchor.
                if let params = Self.decodeParameterSets(payload) {
                    if !debugParamsLogged {
                        debugParamsLogged = true
                        switch params {
                        case .h264(let sps, let pps):
                            logger.log("HelperScreenCapture: paramSets H264 sps=\(sps.count)B pps=\(pps.count)B")
                        case .hevc(let vps, let sps, let pps):
                            logger.log(
                                "HelperScreenCapture: paramSets HEVC vps=\(vps.count)B sps=\(sps.count)B pps=\(pps.count)B"
                            )
                        }
                    }
                    onParameterSets?(params)
                }
                if payload.count >= 9 {
                    let w = Int(Self.readBE32(payload, offset: 1))
                    let h = Int(Self.readBE32(payload, offset: 5))
                    if w > 0 && h > 0 {
                        onEncoderResolution?(w, h)
                    }
                }
            case .firstFrame:
                onFirstFrame?()
            case .previewJPEG:
                onPreviewImage?(payload)
            case .heartbeat:
                // Liveness only — `onActivity` above already recorded it.
                break
            case .logLine:
                if let s = String(data: payload, encoding: .utf8) {
                    logger.log("helper: \(s)")
                }
            case .fatal:
                let msg = String(data: payload, encoding: .utf8) ?? "<no msg>"
                stoppedIntentionally.withLock { $0 = true }  // helper is exiting on purpose
                onUnexpectedExit?("fatal: \(msg)")
                return
            case .userStopped:
                stoppedIntentionally.withLock { $0 = true }
                onUserStopped?()
                return
            }
        }
    }

    /// All indexing is `startIndex`-relative so this is correct for `Data`
    /// slices too, not just zero-based buffers. Internal (not private) so
    /// `ParserFuzzTests` can feed it hostile bytes and re-based slices.
    static func decodeParameterSets(_ data: Data) -> CodecParameterSets? {
        // Layout: [codec:1][width:4 BE][height:4 BE][count:4 BE]([len:4 BE][data:N])*
        guard data.count >= 13 else { return nil }
        let codec = data[data.startIndex]
        // width/height are informational only.
        let count = readBE32(data, offset: 9)
        var cursor = 13
        var paramSets: [Data] = []
        for _ in 0..<count {
            guard cursor + 4 <= data.count else { return nil }
            let len = Int(readBE32(data, offset: cursor))
            cursor += 4
            guard len <= data.count - cursor else { return nil }
            let start = data.index(data.startIndex, offsetBy: cursor)
            let end = data.index(start, offsetBy: len)
            paramSets.append(Data(data[start..<end]))
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

    /// Slice-safe (unlike absolute `data[offset]`). Caller guarantees
    /// `offset + 4 <= data.count`.
    private static func readBE32(_ data: Data, offset: Int) -> UInt32 {
        let base = data.index(data.startIndex, offsetBy: offset)
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[data.index(base, offsetBy: 1)])
        let b2 = UInt32(data[data.index(base, offsetBy: 2)])
        let b3 = UInt32(data[data.index(base, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

enum HelperScreenCaptureError: Error {
    case executableNotFound
}

// MARK: - Logger

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[HelperCapture] \(message)")
    }
}
