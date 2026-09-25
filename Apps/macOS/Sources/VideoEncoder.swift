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
    /// Set before `setup` to override the tuned default; the capture-helper
    /// threads `QualitySettings.encoderQuality` through here.
    var encoderQuality: Double = EncoderTuning.quality
    /// Set-a-property idiom (like `encoderQuality`) keeps `setup` at <=5
    /// parameters. VideoToolbox writes these into the SPS VUI, reaching the
    /// viewer in-band with no wire change.
    var colorInfo: ColorInfo = .bt709FullRange8
    private var forceNextKeyframe = false
    private var lastParameterSets: CodecParameterSets?
    private var activeCodec: VideoCodec = .h264
    /// Capped so backlog doesn't build up on busy pipelines — SCK happily
    /// delivers 60fps faster than VT can encode Retina frames.
    private var inFlight: Int = 0
    private var droppedAtInput: Int = 0
    private let maxInFlight = EncoderTuning.maxInFlight
    /// Latches runtime `setBitrate` property refusals to log once per
    /// session, not once per adaptive-sweep tick. Guarded by `lock`.
    private var didLogRuntimePropertyFailures = false
    private let logger = TSLogger()

    /// `.h264` until the first successful `setup`.
    var codec: VideoCodec {
        lock.lock()
        defer { lock.unlock() }
        return activeCodec
    }

    /// - Parameters:
    ///   - preferredCodec: attempted first, falling back to H.264 if VT
    ///     refuses (e.g. an Intel Mac without HW HEVC).
    ///   - bitsPerPixel: ceiling for `bitsPerPixel x width x height x fps`,
    ///     enforced via `DataRateLimits`. Rate control itself is primarily
    ///     driven by `encoderQuality`.
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

    /// `false` for the explicit-HEVC preference: fail honestly rather than
    /// silently downgrade.
    var allowsH264Fallback = true

    /// HEVC Main 10 falls back to HEVC 8-bit before H.264, so a Mac that
    /// can't encode 10-bit still gets HEVC; H.264 never carries 10-bit here.
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

    /// Kept as one value so `createSession` stays within the 5-parameter
    /// lint ceiling.
    private struct SessionConfig {
        let width: Int
        let height: Int
        let fps: Int32
        let codec: VideoCodec
        let bitsPerPixel: Double
        let colorInfo: ColorInfo
    }

    /// A ceiling, not an average — idle steady-state bandwidth typically
    /// falls well below it since `Quality` drives the actual rate.
    static func defaultBitsPerPixel(for codec: VideoCodec) -> Double {
        EncoderTuning.defaultBitsPerPixel(for: codec)
    }

    /// Records a refused property instead of discarding the OSStatus — a
    /// silently ignored `DataRateLimits` means unbounded bitrate.
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

        var propertyFailures: [String] = []

        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue,
            failures: &propertyFailures)
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

        // Without these, players have been observed picking BT.601 on
        // captured content and shifting reds noticeably.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_ColorPrimaries,
            value: color.primaries.vtKey, failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_TransferFunction,
            value: color.transfer.vtKey, failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: color.matrix.vtKey, failures: &propertyFailures)

        // RealTime=true alone leaves VT free to pick a cheaper trade-off;
        // these flip the explicit tiebreakers toward quality. Best-effort.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanFalse, failures: &propertyFailures)
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse,
            failures: &propertyFailures)

        // Screen content's recurring patterns (cursor blink, scrollback
        // redraw) compress better with a deeper reference window.
        if codec == .hevc {
            Self.setProperty(
                newSession, key: kVTCompressionPropertyKey_ReferenceBufferCount, value: 4 as CFNumber,
                failures: &propertyFailures)
        }

        // Idle screens send near-zero bits, busy frames spend up to the
        // ceiling set in applyBitrate — the right shape for screen sharing.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_Quality, value: encoderQuality as CFNumber,
            failures: &propertyFailures)

        let bitrate = Self.computeBitrate(width: width, height: height, fps: Int(fps), bitsPerPixel: bitsPerPixel)
        Self.applyBitrate(bitrate, to: newSession, failures: &propertyFailures)

        // No pipelining, so wall-clock latency per frame stays predictable.
        Self.setProperty(
            newSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber,
            failures: &propertyFailures)

        // Safety net, not a cadence — IDRs are triggered on demand.
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

    /// Internal (not private): three call sites must agree byte-for-byte —
    /// this encoder's setup, the capture-helper's ceiling clamp, and the
    /// server's adaptive-bitrate baseline anchor.
    static func computeBitrate(width: Int, height: Int, fps: Int, bitsPerPixel: Double) -> Int {
        EncoderTuning.computeBitrate(width: width, height: height, fps: fps, bitsPerPixel: bitsPerPixel)
    }

    /// Deliberately not `AverageBitRate`: rate control runs off `Quality`,
    /// this only configures the peak the encoder may reach. 500ms window,
    /// generous enough for a single IDR burst but tight against tail latency.
    private static func applyBitrate(_ bitrate: Int, to session: VTCompressionSession, failures: inout [String]) {
        let perSecondBytes = bitrate / 8
        let windowSeconds = EncoderTuning.dataRateWindowSeconds
        let windowBytes = Int(Double(perSecondBytes) * EncoderTuning.dataRateBurstFactor * windowSeconds)
        let dataRateLimits = [windowBytes, windowSeconds] as CFArray
        setProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits,
            failures: &failures)
    }

    /// Used by the server's adaptive-bitrate sweep. Safe from any thread.
    func setBitrate(_ bitrate: Int) {
        lock.lock()
        let s = session
        lock.unlock()
        guard let s = s else { return }
        var failures: [String] = []
        Self.applyBitrate(bitrate, to: s, failures: &failures)
        guard !failures.isEmpty else { return }
        lock.lock()
        let shouldLog = !didLogRuntimePropertyFailures
        didLogRuntimePropertyFailures = true
        lock.unlock()
        if shouldLog {
            logger.log("VideoEncoder: unsupported properties: \(failures.joined(separator: ", "))")
        }
    }

    /// Safe from any thread.
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
        // Without this the backlog grows unbounded and the stream ends up
        // several seconds behind live.
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
