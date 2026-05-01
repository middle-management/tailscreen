import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

/// Codec used on the wire. The sharer picks at startup (preferring HEVC
/// when the host's VideoToolbox HW encoder accepts it); the viewer learns
/// it from the RTP payload type. Distinct payload types (96/97) let the
/// receiver demux without negotiation.
enum VideoCodec: String, Codable, Sendable {
    case h264
    case hevc
}

/// Parameter sets needed to build a `CMFormatDescription` for the negotiated
/// codec. H.264 carries SPS+PPS; HEVC additionally carries VPS.
enum CodecParameterSets: Sendable, Equatable {
    case h264(sps: Data, pps: Data)
    case hevc(vps: Data, sps: Data, pps: Data)
}

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
    private var forceNextKeyframe = false
    private var lastParameterSets: CodecParameterSets?
    private var activeCodec: VideoCodec = .h264
    /// Frames handed to VT that haven't come back through the output callback
    /// yet. Capped so we don't build up seconds of encoder backlog on busy
    /// pipelines (ScreenCaptureKit will happily deliver 60fps faster than VT
    /// can encode Retina frames, which otherwise manifests as live-stream lag).
    private var inFlight: Int = 0
    private var droppedAtInput: Int = 0
    private let maxInFlight = 2

    /// Codec the encoder is currently configured for. `.h264` until the
    /// first successful `setup`.
    var codec: VideoCodec {
        lock.lock(); defer { lock.unlock() }
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
    func setup(
        width: Int,
        height: Int,
        fps: Int32 = 60,
        preferredCodec: VideoCodec = .hevc,
        bitsPerPixel: Double? = nil
    ) throws {
        let codecOrder: [VideoCodec] = preferredCodec == .hevc ? [.hevc, .h264] : [.h264]
        var lastError: OSStatus = noErr
        for codec in codecOrder {
            let bpp = bitsPerPixel ?? Self.defaultBitsPerPixel(for: codec)
            do {
                try createSession(width: width, height: height, fps: fps, codec: codec, bitsPerPixel: bpp)
                if codec != preferredCodec {
                    print("VideoEncoder: \(preferredCodec) not available, fell back to \(codec)")
                }
                return
            } catch VideoEncoderError.sessionCreationFailed(let status) {
                lastError = status
                print("VideoEncoder: \(codec) session creation failed (\(status))")
                continue
            }
        }
        throw VideoEncoderError.sessionCreationFailed(lastError)
    }

    /// Default `bitsPerPixel` ceiling for the given codec. HEVC encodes
    /// screen content more efficiently so it gets a lower ceiling for the
    /// same visual quality. Note this is now a ceiling, not an average —
    /// idle steady-state bandwidth typically falls well below it because
    /// `kVTCompressionPropertyKey_Quality` drives the actual rate.
    static func defaultBitsPerPixel(for codec: VideoCodec) -> Double {
        switch codec {
        case .hevc: return 0.08
        case .h264: return 0.10
        }
    }

    private func createSession(width: Int, height: Int, fps: Int32, codec: VideoCodec, bitsPerPixel: Double) throws {
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

        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let profileLevel: CFString = (codec == .hevc)
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        // Tag the bitstream with BT.709 color so decoders don't have to
        // guess. Without these, players have been observed picking BT.601
        // on captured content and shifting reds noticeably.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        // Force the high-quality real-time path. RealTime=true alone leaves
        // VT free to pick a cheaper trade-off; these flip the explicit
        // tiebreakers toward quality. Both are best-effort — older or
        // future VT versions may not honor them, hence we ignore status.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)

        // HEVC: keep more reference frames around. Screen content has lots
        // of recurring patterns (cursor blink, scrollback redraw, repeating
        // UI chrome) that compress dramatically better with a deeper
        // reference window. The decoder reads the new buffering depth from
        // the SPS automatically.
        if codec == .hevc {
            VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ReferenceBufferCount, value: 4 as CFNumber)
        }

        // Drive rate control by perceptual quality with a hard ceiling
        // (DataRateLimits, set in applyBitrate). Idle screens then send
        // near-zero bits while busy frames spend up to the ceiling — the
        // right shape for screen sharing. If the encoder ignores Quality,
        // the ceiling alone still bounds bandwidth.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_Quality, value: 0.7 as CFNumber)

        let bitrate = Self.computeBitrate(width: width, height: height, fps: Int(fps), bitsPerPixel: bitsPerPixel)
        Self.applyBitrate(bitrate, to: newSession)

        // Emit each frame as soon as it's encoded — no pipelining — so the
        // wall-clock latency per frame stays predictable.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // IDRs are triggered on demand (new viewer, explicit refresh). This
        // interval is a safety net, not a cadence.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 10) as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(newSession)

        lock.lock()
        session = newSession
        self.fps = fps
        self.activeCodec = codec
        frameCount = 0
        forceNextKeyframe = true  // first frame out should be an IDR
        lastParameterSets = nil
        lock.unlock()
    }

    private static func computeBitrate(width: Int, height: Int, fps: Int, bitsPerPixel: Double) -> Int {
        Int(Double(width * height) * bitsPerPixel * Double(fps))
    }

    /// Sets the bandwidth ceiling via `DataRateLimits`. We deliberately do
    /// NOT set `AverageBitRate`: rate control runs primarily off
    /// `kVTCompressionPropertyKey_Quality` (configured once in
    /// `createSession`), and this function configures the upper bound the
    /// encoder is allowed to peak to. We allow 1.75× the per-second budget
    /// over a 500 ms window — generous enough for a single IDR burst but
    /// tight enough to prevent burst tail latency.
    private static func applyBitrate(_ bitrate: Int, to session: VTCompressionSession) {
        let perSecondBytes = bitrate / 8
        let windowBytes = Int(Double(perSecondBytes) * 1.75 / 2.0)
        let windowSeconds = 0.5
        let dataRateLimits = [windowBytes, windowSeconds] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
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
        Self.applyBitrate(bitrate, to: s)
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
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        let isKeyframe = !sampleBuffer.isNotSync
        let paramCallback = onParameterSets
        let dataCallback = onEncodedData

        if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let params = Self.extractParameterSets(from: formatDescription, codec: codec) {
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

    private static func extractParameterSets(from formatDescription: CMFormatDescription, codec: VideoCodec) -> CodecParameterSets? {
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
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let attachment = attachments.first else {
            return true
        }
        return attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
}

enum VideoEncoderError: Error {
    case sessionCreationFailed(OSStatus)
}
