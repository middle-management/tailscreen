import VideoToolbox
import CoreMedia
import CoreVideo
import AppKit

final class VideoDecoder: @unchecked Sendable {
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "com.tailscreen.decoder")
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?

    /// Install explicit H.264 parameter sets. The server sends these before any frames,
    /// and re-sends them on every IDR so late joiners can recover without guessing.
    func setParameterSets(sps: Data, pps: Data) {
        queue.async { [weak self] in
            self?.applyParameterSets(sps: sps, pps: pps)
        }
    }

    /// Decode one AVCC-formatted access unit (length-prefixed NAL units).
    /// Silently drops the frame if no parameter sets have been installed yet.
    func decode(data: Data, isKeyframe: Bool) {
        queue.async { [weak self] in
            self?.decodeOnQueue(data: data, isKeyframe: isKeyframe)
        }
    }

    private func applyParameterSets(sps: Data, pps: Data) {
        var newDesc: CMFormatDescription?
        let status = sps.withUnsafeBytes { (spsBuf: UnsafeRawBufferPointer) -> OSStatus in
            pps.withUnsafeBytes { (ppsBuf: UnsafeRawBufferPointer) -> OSStatus in
                guard let spsBase = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrs in
                    sizes.withUnsafeBufferPointer { szs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: szs.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let desc = newDesc else {
            print("VideoDecoder: failed to build format description (\(status))")
            return
        }

        if let existing = formatDescription, CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
            return
        }

        if let existingSession = session {
            VTDecompressionSessionInvalidate(existingSession)
            session = nil
        }
        formatDescription = desc
    }

    private func decodeOnQueue(data: Data, isKeyframe: Bool) {
        guard let formatDescription = formatDescription else { return }

        if session == nil {
            createDecompressionSession(formatDescription: formatDescription)
        }
        guard let session = session else { return }

        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
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
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else { return }

        let copyStatus = data.withUnsafeBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

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
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else { return }

        _ = isKeyframe  // VT infers sync/no-sync from NAL types; we use the flag only for UI state.

        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        if decodeStatus != noErr {
            print("VideoDecoder: DecodeFrame failed status=\(decodeStatus) (isKeyframe=\(isKeyframe), \(data.count)B)")
        }
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) {
        var session: VTDecompressionSession?

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard let refcon = refcon else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                if status != noErr {
                    print("VideoDecoder: output callback reported status=\(status)")
                    return
                }
                guard let imageBuffer = imageBuffer else {
                    print("VideoDecoder: output callback got nil imageBuffer")
                    return
                }
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
        } else {
            print("VideoDecoder: failed to create decompression session (\(status))")
        }
    }

    func shutdown() {
        // Drain in-flight async decodes BEFORE invalidating. VT's
        // Invalidate doesn't wait for submitted frames to finish; the
        // output callback can fire after Invalidate returns, retain a
        // CVPixelBuffer whose backing is gone, and SIGSEGV the caller
        // (e.g. TailscaleScreenShareClient.handleDecodedFrame doing
        // objc_retain on a dead pointer when the viewer's window-close
        // button triggers disconnect mid-decode).
        queue.sync {
            if let session = session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                self.onDecodedFrame = nil
                VTDecompressionSessionInvalidate(session)
            } else {
                self.onDecodedFrame = nil
            }
            session = nil
            formatDescription = nil
        }
    }
}
