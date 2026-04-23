import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

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

    /// Emits H.264 parameter sets (SPS, PPS) on every IDR so late joiners
    /// can rebuild a decoder session. Fires before the matching frame.
    var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var fps: Int32 = 60
    private var forceNextKeyframe = false
    private var lastSPS: Data?
    private var lastPPS: Data?
    /// Frames handed to VT that haven't come back through the output callback
    /// yet. Capped so we don't build up seconds of encoder backlog on busy
    /// pipelines (ScreenCaptureKit will happily deliver 60fps faster than VT
    /// can encode Retina frames, which otherwise manifests as live-stream lag).
    private var inFlight: Int = 0
    private var droppedAtInput: Int = 0
    private let maxInFlight = 2

    /// - Parameters:
    ///   - width: pixel width
    ///   - height: pixel height
    ///   - fps: target frame rate
    ///   - bitsPerPixel: quality knob. 0.08 is plenty for screen content and
    ///     matters for latency because the previous 0.15 produced ~550 KB
    ///     keyframes at Retina resolutions that stalled viewers for ~200 ms.
    func setup(width: Int, height: Int, fps: Int32 = 60, bitsPerPixel: Double = 0.08) throws {
        var newSession: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard status == noErr, let newSession = newSession else {
            throw VideoEncoderError.sessionCreationFailed
        }

        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        let bitrate = Int(Double(width * height) * bitsPerPixel * Double(fps))
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Hard cap per-window bytes. Without this the encoder honors the
        // average but is free to emit a ~10x spike on a single keyframe.
        // Format: alternating [maxBytesInWindow, windowSeconds]. Allow 1.75x
        // the per-second budget over a 500 ms window — generous enough for
        // a single IDR but tight enough to prevent the burst tail latency.
        let perSecondBytes = bitrate / 8
        let windowBytes = Int(Double(perSecondBytes) * 1.75 / 2.0)
        let windowSeconds = 0.5
        let dataRateLimits = [windowBytes, windowSeconds] as CFArray
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

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
        frameCount = 0
        forceNextKeyframe = true  // first frame out should be an IDR
        lastSPS = nil
        lastPPS = nil
        lock.unlock()
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
           let (sps, pps) = Self.extractParameterSets(from: formatDescription) {
            lock.lock()
            lastSPS = sps
            lastPPS = pps
            lock.unlock()
            paramCallback?(sps, pps)
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

    private static func extractParameterSets(from formatDescription: CMFormatDescription) -> (sps: Data, pps: Data)? {
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

    /// Last emitted parameter sets, if any. Thread-safe.
    var cachedParameterSets: (sps: Data, pps: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard let sps = lastSPS, let pps = lastPPS else { return nil }
        return (sps, pps)
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
    case sessionCreationFailed
}
