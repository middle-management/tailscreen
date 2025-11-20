import VideoToolbox
import CoreMedia
import CoreVideo

class VideoEncoder {
    private var session: VTCompressionSession?
    private var frameCount: Int64 = 0
    var onEncodedData: ((Data, Bool) -> Void)?

    func setup(width: Int, height: Int) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw VideoEncoderError.sessionCreationFailed
        }

        self.session = session

        // Configure for high quality and low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Set quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.8 as CFNumber)

        // Set average bitrate (higher for better quality)
        let bitrate = width * height * 4 // ~4 bits per pixel for high quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Set keyframe interval
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(pixelBuffer: CVPixelBuffer) {
        guard let session = session else { return }

        let presentationTimeStamp = CMTime(value: frameCount, timescale: 60)
        frameCount += 1

        var flags: VTEncodeInfoFlags = []

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.handleEncodedFrame(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
        }

        if status != noErr {
            print("Encoding frame failed: \(status)")
        }
    }

    private func handleEncodedFrame(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        // Check if this is a keyframe
        let isKeyframe = !sampleBuffer.isNotSync

        // Get the encoded data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: length)

        data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }

        onEncodedData?(data, isKeyframe)
    }

    func shutdown() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }
}

extension CMSampleBuffer {
    var isNotSync: Bool {
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
