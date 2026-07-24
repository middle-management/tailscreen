import CoreMedia
import CoreVideo
import Foundation
import TailscaleKit
import VideoToolbox

// VideoCodec / CodecParameterSets / EncoderTuning live in
// VideoCodecTypes.swift (platform-portable, part of TailscreenProtocol).

private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}

final class VideoEncoder: @unchecked Sendable {
    /// Emits the AVCC-formatted compressed frame plus its keyframe flag.
    /// Fires from VideoToolbox's encoder thread; receivers must be thread-safe.
    var onEncodedData: ((Data, Bool) -> Void)?

    /// Emits codec parameter sets on every IDR so late joiners can rebuild
    /// a decoder session. Fires before the matching frame.
    var onParameterSets: ((CodecParameterSets) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var fps: Int32 = 60
    /// Perceptual-quality target for `kVTCompressionPropertyKey_Quality`,
    /// read by `createSession`. Set before `setup` to override the tuned
    /// default; the capture-helper threads `QualitySettings.encoderQuality`
    /// through here.
    var encoderQuality: Double = EncoderTuning.quality
    /// Color characteristics (primaries/transfer/matrix, bit depth, range)
    /// the session is tagged with. Set before `setup` to override the shipped
    /// BT.709 8-bit default; the capture-helper threads the display's
    /// `ColorInfo` through here. Same set-a-property idiom as `encoderQuality`,
    /// which keeps `setup` at ≤5 parameters. VideoToolbox writes these into
    /// the SPS VUI so they reach the viewer in-band with no wire change.
    var colorInfo: ColorInfo = .bt709FullRange8
    private var forceNextKeyframe = false
    private var lastParameterSets: CodecParameterSets?
    private var activeCodec: VideoCodec = .h264
    /// Frames handed to VT that haven't come back through the output callback
    /// yet. Capped so we don't build up seconds of encoder backlog on busy
    /// pipelines (ScreenCaptureKit will happily deliver 60fps faster than VT
    /// can encode Retina frames, which otherwise manifests as live-stream lag).
    private var inFlight: Int = 0
    private var droppedAtInput: Int = 0
    private let maxInFlight = EncoderTuning.maxInFlight
    /// Latch so property refusals from runtime `setBitrate` calls log once
    /// per session instead of once per adaptive-sweep tick. Cleared on
    /// `createSession`. Guarded by `lock`.
    private var didLogRuntimePropertyFailures = false
    private let logger = TSLogger()

    /// Codec the encoder is currently configured for. `.h264` until the
    /// first successful `setup`.
    var codec: VideoCodec {
        lock.lock()
        defer { lock.unlock() }
        return activeCodec
    }

    /// - Parameters:
    ///   - width: pixel width
    ///   - height: pixel height
    ///   - fps: target frame rate
    ///   - preferredCodec: codec to try first. We attempt that one and fall
    ///     back to H.264 if VT refuses (e.g. an Intel Mac without HW HEVC).
    ///   - bitsPerPixel: ceiling for the rate-control window. We drive the
    ///     encoder primarily by `kVTCompressionPropertyKey_Quality` and use
    ///     `bitsPerPixel × width × height × fps` as the upper bound enforced
    ///     via `DataRateLimits`. HEVC's intra-prediction modes for screen
    ///     content earn back ~30% efficiency vs H.264, so the HEVC default
    ///     is lower; idle screens routinely settle far below the ceiling
    ///     because Quality lets the encoder skip bits when nothing changed.
    ///
    /// The perceptual-quality target (`kVTCompressionPropertyKey_Quality`)
    /// is taken from the `encoderQuality` property — set it before calling
    /// `setup` to override the tuned default (the capture-helper threads the
    /// user's `QualitySettings.encoderQuality` through that property).
    func setup(
        width: Int,
        height: Int,
        fps: Int32 = 60,
        preferredCodec: VideoCodec = .hevc,
        bitsPerPixel: Double? = nil
    ) throws {
        let requested = colorInfo
        let attempts = Self.sessionAttempts(
            preferredCodec: preferredCodec, colorInfo: requested,
            allowH264Fallback: allowsH264Fallback)
        var lastError: OSStatus = noErr
        for attempt in attempts {
            let bpp = bitsPerPixel ?? Self.defaultBitsPerPixel(for: attempt.codec)
            let attemptTag = "\(attempt.codec)/\(attempt.colorInfo.bitDepth)bit"
            let config = SessionConfig(
                width: width, height: height, fps: fps, codec: attempt.codec, bitsPerPixel: bpp,
                colorInfo: attempt.colorInfo)
            do {
                try createSession(config)
                let fellBack = attempt.codec != preferredCodec || attempt.colorInfo.bitDepth != requested.bitDepth
                if fellBack {
                    let want = "\(preferredCodec)/\(requested.bitDepth)bit"
                    print("VideoEncoder: \(want) unavailable, using \(attemptTag)")
                }
                return
            } catch VideoEncoderError.sessionCreationFailed(let status) {
                lastError = status
                print("VideoEncoder: \(attemptTag) session creation failed (\(status))")
                continue
            }
        }
        throw VideoEncoderError.sessionCreationFailed(lastError)
    }

    /// Whether the fallback ladder may end on an H.264 rung. `false` for
    /// the explicit-HEVC codec preference: the user opted out of the
    /// safety net, so an encoder that can't do HEVC fails the share
    /// honestly instead of silently downgrading. A property (like
    /// `colorInfo` / `encoderQuality`) rather than a `setup` parameter to
    /// stay within the 5-parameter lint ceiling.
    var allowsH264Fallback = true

    /// Ordered (codec, colorInfo) attempts for the fallback ladder. HEVC
    /// Main 10 falls back to HEVC 8-bit before H.264 (mirroring the shipped
    /// HEVC→H.264 ladder), so a Mac that can't encode 10-bit still gets HEVC;
    /// H.264 never carries 10-bit here. `allowH264Fallback: false` (the
    /// explicit-HEVC preference) drops the trailing H.264 rung — but never
    /// affects an H.264 *preference*, which is its own single-rung ladder.
    /// Pure and CI-tested.
    static func sessionAttempts(
        preferredCodec: VideoCodec, colorInfo: ColorInfo, allowH264Fallback: Bool = true
    ) -> [(codec: VideoCodec, colorInfo: ColorInfo)] {
        guard preferredCodec == .hevc else {
            let ci = colorInfo.bitDepth >= 10 ? colorInfo.downgradedTo8Bit() : colorInfo
            return [(.h264, ci)]
        }
        var attempts: [(codec: VideoCodec, colorInfo: ColorInfo)] = []
        if colorInfo.bitDepth >= 10 {
            attempts.append((.hevc, colorInfo))
            attempts.append((.hevc, colorInfo.downgradedTo8Bit()))
        } else {
            attempts.append((.hevc, colorInfo))
        }
        if allowH264Fallback {
            attempts.append((.h264, colorInfo.downgradedTo8Bit()))
        }
        return attempts
    }

    /// Bundle of per-session settings, kept as one value so `createSession`
    /// stays within the 5-parameter lint ceiling as color characteristics
    /// were threaded in.
    private struct SessionConfig {
        let width: Int
        let height: Int
        let fps: Int32
        let codec: VideoCodec
        let bitsPerPixel: Double
        let colorInfo: ColorInfo
    }

    /// Default `bitsPerPixel` ceiling for the given codec. HEVC encodes
    /// screen content more efficiently so it gets a lower ceiling for the
    /// same visual quality. Note this is now a ceiling, not an average —
    /// idle steady-state bandwidth typically falls well below it because
    /// `kVTCompressionPropertyKey_Quality` drives the actual rate.
    static func defaultBitsPerPixel(for codec: VideoCodec) -> Double {
        // Single source of truth lives in the portable tuning layer.
        EncoderTuning.defaultBitsPerPixel(for: codec)
    }

    /// `VTSessionSetProperty` wrapper that records a refused property (by
    /// name and status) instead of discarding the OSStatus. Most of these
    /// properties are best-effort tuning knobs, so a refusal isn't fatal —
    /// but a silently ignored `DataRateLimits` means unbounded bitrate,
    /// which is worth naming in the log once per session.
    private static func setProperty(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef,
        failures: inout [String]
    ) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            failures.append("\(key)=\(status)")
        }
    }

    private func createSession(_ config: SessionConfig) throws {
        let width = config.width
        let height = config.height
        let fps = config.fps
        let codec = config.codec
        let bitsPerPixel = config.bitsPerPixel
        let color = config.colorInfo
        var newSession: VTCompressionSession?

        let codecType: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard status == noErr, let newSession = newSession else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        // Property refusals are collected here and logged once, by name,
        // after the configuration block — VT support varies by hardware and
        // OS, and a session that silently dropped e.g. DataRateLimits used
        // to run unbounded-bitrate with no trace in the logs.
        var propertyFailures: [String] = []

        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue,
            failures: &propertyFailures)
        // Profile follows the codec + bit depth: HEVC Main 10 for 10-bit,
        // Main for 8-bit HEVC, High for H.264 (never 10-bit here).
        let profileLevel = color.profileLevel(for: codec)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel,
            failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse,
            failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber,
            failures: &propertyFailures)

        // Tag the bitstream with the captured color so decoders don't have to
        // guess. Without these, players have been observed picking BT.601 on
        // captured content and shifting reds noticeably. These come from the
        // capture-helper's `ColorInfo` (BT.709 by default, Display P3 on
        // wide-gamut displays, BT.2020 PQ/HLG for HDR); VideoToolbox writes
        // them into the SPS VUI so the viewer reads them back in-band.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_ColorPrimaries,
            value: color.primaries.vtKey, failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_TransferFunction,
            value: color.transfer.vtKey, failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: color.matrix.vtKey, failures: &propertyFailures)

        // Force the high-quality real-time path. RealTime=true alone leaves
        // VT free to pick a cheaper trade-off; these flip the explicit
        // tiebreakers toward quality. Both are best-effort — older or
        // future VT versions may not honor them; a refusal is only named in
        // the log, never fatal.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanFalse, failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse,
            failures: &propertyFailures)

        // HEVC: keep more reference frames around. Screen content has lots
        // of recurring patterns (cursor blink, scrollback redraw, repeating
        // UI chrome) that compress dramatically better with a deeper
        // reference window. The decoder reads the new buffering depth from
        // the SPS automatically.
        if codec == .hevc {
            Self.setProperty(
                newSession, key: kVTCompressionPropertyKey_ReferenceBufferCount, value: 4 as CFNumber,
                failures: &propertyFailures)
        }

        // Drive rate control by perceptual quality with a hard ceiling
        // (DataRateLimits, set in applyBitrate). Idle screens then send
        // near-zero bits while busy frames spend up to the ceiling — the
        // right shape for screen sharing. If the encoder ignores Quality,
        // the ceiling alone still bounds bandwidth.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_Quality, value: encoderQuality as CFNumber,
            failures: &propertyFailures)

        let bitrate = Self.computeBitrate(width: width, height: height, fps: Int(fps), bitsPerPixel: bitsPerPixel)
        Self.applyBitrate(bitrate, to: newSession, failures: &propertyFailures)

        // Emit each frame as soon as it's encoded — no pipelining — so the
        // wall-clock latency per frame stays predictable.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber,
            failures: &propertyFailures)

        // IDRs are triggered on demand (new viewer, explicit refresh). This
        // interval is a safety net, not a cadence.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: (fps * EncoderTuning.keyframeIntervalMultiplier) as CFNumber,
            failures: &propertyFailures)

        if !propertyFailures.isEmpty {
            logger.log("VideoEncoder: unsupported properties: \(propertyFailures.joined(separator: ", "))")
        }

        VTCompressionSessionPrepareToEncodeFrames(newSession)

        lock.lock()
        session = newSession
        self.fps = fps
        self.activeCodec = codec
        frameCount = 0
        forceNextKeyframe = true  // first frame out should be an IDR
        lastParameterSets = nil
        didLogRuntimePropertyFailures = false
        lock.unlock()
    }

    /// The bitrate-ceiling formula (`w × h × bpp × fps`). Internal (not
    /// private) because it's the single source of truth shared by three
    /// call sites that must agree byte-for-byte: this encoder's session
    /// setup, the capture-helper's user-ceiling clamp
    /// (`CaptureHelperRunner.handleFrame`), and the server's
    /// adaptive-bitrate baseline anchor (`onEncoderResolution`).
    static func computeBitrate(width: Int, height: Int, fps: Int, bitsPerPixel: Double) -> Int {
        Int(Double(width * height) * bitsPerPixel * Double(fps))
    }

    /// Sets the bandwidth ceiling via `DataRateLimits`. We deliberately do
    /// NOT set `AverageBitRate`: rate control runs primarily off
    /// `kVTCompressionPropertyKey_Quality` (configured once in
    /// `createSession`), and this function configures the upper bound the
    /// encoder is allowed to peak to. We allow 1.75× the per-second budget
    /// over a 500 ms window — generous enough for a single IDR burst but
    /// tight enough to prevent burst tail latency.
    private static func applyBitrate(_ bitrate: Int, to session: VTCompressionSession, failures: inout [String]) {
        let perSecondBytes = bitrate / 8
        let windowSeconds = EncoderTuning.dataRateWindowSeconds
        let windowBytes = Int(Double(perSecondBytes) * EncoderTuning.dataRateBurstFactor * windowSeconds)
        let dataRateLimits = [windowBytes, windowSeconds] as CFArray
        setProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits,
            failures: &failures)
    }

    /// Update the encoder's bandwidth ceiling while it's running. Used by
    /// the adaptive-bitrate sweep on the server: cut on sustained PLI
    /// bursts, recover on clean stream. The encoder's actual rate is
    /// driven by Quality and may sit well below this ceiling on idle
    /// content. Safe to call from any thread.
    func setBitrate(_ bitrate: Int) {
        lock.lock()
        let s = session
        lock.unlock()
        guard let s = s else { return }
        var failures: [String] = []
        Self.applyBitrate(bitrate, to: s, failures: &failures)
        guard !failures.isEmpty else { return }
        // The adaptive sweep calls this every few seconds; latch so a
        // machine that refuses DataRateLimits logs once per session, not
        // once per tick.
        lock.lock()
        let shouldLog = !didLogRuntimePropertyFailures
        didLogRuntimePropertyFailures = true
        lock.unlock()
        if shouldLog {
            logger.log("VideoEncoder: unsupported properties: \(failures.joined(separator: ", "))")
        }
    }

    /// Request that the next encoded frame be an IDR. Safe from any thread.
    func requestKeyframe() {
        lock.lock()
        forceNextKeyframe = true
        lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard let session = session else {
            lock.unlock()
            return
        }
        // Drop this frame if the encoder is already saturated. Without this
        // the backlog grows unbounded and the stream ends up several seconds
        // behind live.
        if inFlight >= maxInFlight && !forceNextKeyframe {
            droppedAtInput += 1
            if droppedAtInput == 1 || droppedAtInput % 60 == 0 {
                print("VideoEncoder: dropped \(droppedAtInput) input frames (encoder saturated)")
            }
            lock.unlock()
            return
        }
        let pts = CMTime(value: frameCount, timescale: fps)
        frameCount += 1
        var frameProps: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        inFlight += 1
        lock.unlock()

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        if status != noErr {
            lock.lock()
            inFlight -= 1
            lock.unlock()
            print("VideoEncoder: encode failed (\(status))")
        }
    }

    fileprivate func handleEncodedFrame(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        // Always decrement inFlight regardless of success — VT has finished
        // this frame one way or another.
        lock.lock()
        if inFlight > 0 { inFlight -= 1 }
        let codec = activeCodec
        lock.unlock()

        guard status == noErr,
            let sampleBuffer = sampleBuffer,
            CMSampleBufferDataIsReady(sampleBuffer)
        else {
            return
        }

        let isKeyframe = !sampleBuffer.isNotSync
        let paramCallback = onParameterSets
        let dataCallback = onEncodedData

        if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let params = Self.extractParameterSets(from: formatDescription, codec: codec)
        {
            lock.lock()
            lastParameterSets = params
            lock.unlock()
            paramCallback?(params)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else { return }

        dataCallback?(data, isKeyframe)
    }

    private static func extractParameterSets(
        from formatDescription: CMFormatDescription, codec: VideoCodec
    ) -> CodecParameterSets? {
        switch codec {
        case .h264:
            guard let (sps, pps) = extractH264(formatDescription: formatDescription) else { return nil }
            return .h264(sps: sps, pps: pps)
        case .hevc:
            guard let (vps, sps, pps) = extractHEVC(formatDescription: formatDescription) else { return nil }
            return .hevc(vps: vps, sps: sps, pps: pps)
        }
    }

    private static func extractH264(formatDescription: CMFormatDescription) -> (sps: Data, pps: Data)? {
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        var count = 0
        var nalHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard spsStatus == noErr, let sps = spsPtr, count >= 2 else { return nil }

        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        guard ppsStatus == noErr, let pps = ppsPtr else { return nil }

        return (Data(bytes: sps, count: spsSize), Data(bytes: pps, count: ppsSize))
    }

    private static func extractHEVC(formatDescription: CMFormatDescription) -> (vps: Data, sps: Data, pps: Data)? {
        var vpsPtr: UnsafePointer<UInt8>?
        var vpsSize = 0
        var count = 0
        var nalHeaderLength: Int32 = 0

        let vpsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: &vpsPtr, parameterSetSizeOut: &vpsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard vpsStatus == noErr, let vps = vpsPtr, count >= 3 else { return nil }

        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        let spsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 1,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        guard spsStatus == noErr, let sps = spsPtr else { return nil }

        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        let ppsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 2,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        guard ppsStatus == noErr, let pps = ppsPtr else { return nil }

        return (
            Data(bytes: vps, count: vpsSize),
            Data(bytes: sps, count: spsSize),
            Data(bytes: pps, count: ppsSize)
        )
    }

    /// Last emitted parameter sets, if any. Thread-safe.
    var cachedParameterSets: CodecParameterSets? {
        lock.lock()
        defer { lock.unlock() }
        return lastParameterSets
    }

    func shutdown() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s = s {
            VTCompressionSessionInvalidate(s)
        }
    }
}

extension CMSampleBuffer {
    fileprivate var isNotSync: Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[CFString: Any]],
            let attachment = attachments.first
        else {
            return true
        }
        return attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
}

enum VideoEncoderError: Error {
    case sessionCreationFailed(OSStatus)
}

// MARK: - Logger

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[VideoEncoder] \(message)")
    }
}
