import VideoToolbox
import CoreMedia
import CoreVideo
import AppKit

class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    func decode(data: Data, isKeyframe: Bool) {
        // Extract SPS and PPS for format description if this is a keyframe
        if isKeyframe {
            updateFormatDescription(from: data)
        }

        guard let formatDescription = formatDescription else {
            print("No format description available")
            return
        }

        // Ensure session is created
        if session == nil {
            createDecompressionSession(formatDescription: formatDescription)
        }

        guard let session = session else {
            print("Failed to create decompression session")
            return
        }

        // Create block buffer from data
        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == noErr, let blockBuffer = blockBuffer else {
            print("Failed to create block buffer")
            return
        }

        // Copy data into block buffer
        data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSizes = [data.count]

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            print("Failed to create sample buffer")
            return
        }

        // Decode the frame
        var flagsOut: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }

    private func updateFormatDescription(from data: Data) {
        // Parse NAL units to find SPS and PPS
        var sps: Data?
        var pps: Data?

        var offset = 0
        while offset < data.count - 4 {
            let startCode = data[offset..<offset+4]
            if startCode == Data([0x00, 0x00, 0x00, 0x01]) {
                // Find next start code
                var nextOffset = offset + 4
                while nextOffset < data.count - 3 {
                    let nextCode = data[nextOffset..<nextOffset+4]
                    if nextCode == Data([0x00, 0x00, 0x00, 0x01]) {
                        break
                    }
                    nextOffset += 1
                }

                let nalUnit = data[(offset+4)..<min(nextOffset, data.count)]
                if !nalUnit.isEmpty {
                    let nalType = nalUnit[0] & 0x1F

                    if nalType == 7 { // SPS
                        sps = nalUnit
                    } else if nalType == 8 { // PPS
                        pps = nalUnit
                    }
                }

                offset = nextOffset
            } else {
                offset += 1
            }
        }

        // Create format description if we have SPS and PPS
        if let sps = sps, let pps = pps {
            let parameterSets = [sps, pps]
            let sizes = parameterSets.map { $0.count }

            parameterSets.withUnsafeBufferPointer { paramPtr in
                sizes.withUnsafeBufferPointer { sizePtr in
                    let pointers = paramPtr.map { $0.withUnsafeBytes { $0.baseAddress! } }
                    pointers.withUnsafeBufferPointer { ptrPtr in
                        var desc: CMFormatDescription?
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: parameterSets.count,
                            parameterSetPointers: ptrPtr.baseAddress!,
                            parameterSetSizes: sizePtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                        formatDescription = desc
                    }
                }
            }
        }
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) {
        var session: VTDecompressionSession?

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
                guard status == noErr,
                      let imageBuffer = imageBuffer else {
                    return
                }

                let decoder = Unmanaged<VideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
                decoder.onDecodedFrame?(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        if status == noErr {
            self.session = session
        }
    }

    func shutdown() {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }
}
