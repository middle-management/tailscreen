import AppKit
import CoreMedia
import CoreVideo
import TailscaleKit
import TailscreenViewer
import VideoToolbox
import os

// The escalation ladder decision (`DecodeRecoveryAction` rungs, thresholds,
// `DecodeRecovery.action`) lives in the portable `TailscreenViewer` tier,
// shared via `ViewerSession`. This decoder is the mac-side application: the
// on-queue counter/latch, the VideoToolbox session rebuild, and the
// pass-through callbacks the client drives UI from.

final class VideoDecoder: @unchecked Sendable {
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    /// Fires once per codec when VideoToolbox can't build a session — almost
    /// always HEVC on a Mac without HEVC decode. Called on `queue`.
    var onDecodeFailure: ((VideoCodec) -> Void)?

    /// Called on `queue` for every per-frame decode failure.
    var onFrameDecodeFailed: (() -> Void)?

    /// Called on `queue` when the consecutive-failure count crosses an
    /// escalation threshold. `.recreateSession` is already handled internally
    /// by the time this fires; other rungs are the client's job.
    var onRecoveryAction: ((DecodeRecoveryAction) -> Void)?

    /// Called on `queue` after a successful frame following `.signalDegraded`.
    var onRecovered: (() -> Void)?

    private let queue = DispatchQueue(label: "com.tailscreen.decoder")
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    /// So a session-create failure can report *which* codec failed.
    private var currentCodec: VideoCodec?
    /// Latched so a black-screened viewer doesn't fire `onDecodeFailure` once
    /// per frame. Reset when the installed codec changes.
    private var didReportDecodeFailure = false
    /// Mutated only on `queue`; drives the portable escalation ladder.
    private var consecutiveFailures = 0
    /// Paired with `DecodeRecovery.action`'s `>=` thresholds so each rung
    /// fires once per episode even when the counter skips a value.
    private var firedRecoveryActions: Set<DecodeRecoveryAction> = []
    /// True between `.recreateSession` tearing the session down and the next
    /// rebuild. While set, a create failure only logs — `onDecodeFailure`
    /// (the codec-unsupported alert) is reserved for the initial create;
    /// mid-session rebuild failures keep counting through the ladder instead.
    private var isRebuildingSession = false
    /// Skips a per-frame `recordDecodeSuccessOnQueue` hop on the healthy path
    /// — at 60fps that async would otherwise write 0 over 0 for nothing.
    /// Locked: read on VideoToolbox's thread, written on `queue`.
    private let episodeActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let logger = TSLogger()

    // MARK: - Decode-failure escalation ladder

    /// `.recreateSession` is handled here (the session is this class's own
    /// state); every rung also forwards to `onRecoveryAction`. `reason` feeds
    /// a throttled log line (first, then every 60th) so a stalled stream
    /// doesn't emit 60 lines/s. Must run on `queue`.
    private func recordDecodeFailureOnQueue(reason: String) {
        consecutiveFailures += 1
        episodeActive.withLock { $0 = true }
        if consecutiveFailures == 1 || consecutiveFailures % 60 == 0 {
            logger.log("VideoDecoder: decode failure #\(consecutiveFailures): \(reason)")
        }
        onFrameDecodeFailed?()
        let decision = DecodeRecovery.action(
            consecutiveFailures: consecutiveFailures, alreadyFired: firedRecoveryActions)
        guard let action = decision else { return }
        firedRecoveryActions.insert(action)
        logger.log("VideoDecoder: \(consecutiveFailures) consecutive decode failures — escalating to \(action)")
        if action == .recreateSession {
            recreateSessionOnQueue()
        }
        onRecoveryAction?(action)
    }

    /// Must run on `queue`.
    private func recordDecodeSuccessOnQueue() {
        let wasDegraded = firedRecoveryActions.contains(.signalDegraded)
        consecutiveFailures = 0
        firedRecoveryActions.removeAll()
        episodeActive.withLock { $0 = false }
        if wasDegraded {
            logger.log("VideoDecoder: decoding recovered")
            onRecovered?()
        }
    }

    /// Reuses `shutdown()`'s drain-before-invalidate ordering but keeps the
    /// format description and callbacks — the stream is still live. Must run
    /// on `queue`.
    private func recreateSessionOnQueue() {
        guard let session = session else { return }
        logger.log("VideoDecoder: recreating decompression session after persistent decode failures")
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        isRebuildingSession = true
    }

    func setParameterSets(_ params: CodecParameterSets) {
        queue.async { [weak self] in
            self?.applyParameterSets(params)
        }
    }

    /// A frame arriving before parameter sets are installed counts as a
    /// decode failure so the ladder can request the keyframe that carries them.
    func decode(data: Data, isKeyframe: Bool) {
        queue.async { [weak self] in
            self?.decodeOnQueue(data: data, isKeyframe: isKeyframe)
        }
    }

    private func applyParameterSets(_ params: CodecParameterSets) {
        let newDesc: CMFormatDescription?
        let codec: VideoCodec
        switch params {
        case .h264(let sps, let pps):
            newDesc = Self.makeH264FormatDescription(sps: sps, pps: pps)
            codec = .h264
        case .hevc(let vps, let sps, let pps):
            newDesc = Self.makeHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
            codec = .hevc
        }

        guard let desc = newDesc else {
            logger.log("VideoDecoder: failed to build format description")
            return
        }

        // New codec: clear the latch so it gets a fresh chance to be reported.
        if codec != currentCodec {
            currentCodec = codec
            didReportDecodeFailure = false
        }

        if let existing = formatDescription, CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
            return
        }

        if let existingSession = session {
            VTDecompressionSessionInvalidate(existingSession)
            session = nil
        }
        formatDescription = desc
        // Fresh format description means the next create is initial, not a
        // mid-episode rebuild.
        isRebuildingSession = false
    }

    private static func makeH264FormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var newDesc: CMFormatDescription?
        let status = sps.withUnsafeBytes { (spsBuf: UnsafeRawBufferPointer) -> OSStatus in
            pps.withUnsafeBytes { (ppsBuf: UnsafeRawBufferPointer) -> OSStatus in
                guard let spsBase = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let ppsBase = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
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
        guard status == noErr else {
            TSLogger().log("VideoDecoder: H.264 format description failed (\(status))")
            return nil
        }
        return newDesc
    }

    private static func makeHEVCFormatDescription(vps: Data, sps: Data, pps: Data) -> CMFormatDescription? {
        var newDesc: CMFormatDescription?
        let status = vps.withUnsafeBytes { (vpsBuf: UnsafeRawBufferPointer) -> OSStatus in
            sps.withUnsafeBytes { (spsBuf: UnsafeRawBufferPointer) -> OSStatus in
                pps.withUnsafeBytes { (ppsBuf: UnsafeRawBufferPointer) -> OSStatus in
                    guard let vpsBase = vpsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let spsBase = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let ppsBase = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else {
                        return -1
                    }
                    let pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { ptrs in
                        sizes.withUnsafeBufferPointer { szs in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: ptrs.baseAddress!,
                                parameterSetSizes: szs.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &newDesc
                            )
                        }
                    }
                }
            }
        }
        guard status == noErr else {
            TSLogger().log("VideoDecoder: HEVC format description failed (\(status))")
            return nil
        }
        return newDesc
    }

    private func decodeOnQueue(data: Data, isKeyframe: Bool) {
        // Both early-outs below MUST count as failures, or the ladder freezes
        // at the recreate rung when the rebuild keeps failing.
        guard let formatDescription = formatDescription else {
            recordDecodeFailureOnQueue(reason: "no format description installed yet")
            return
        }

        if session == nil {
            createDecompressionSession(formatDescription: formatDescription)
        }
        guard let session = session else {
            recordDecodeFailureOnQueue(reason: "no decompression session (create failed)")
            return
        }

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
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
            recordDecodeFailureOnQueue(reason: "block-buffer create failed (\(allocStatus))")
            return
        }

        let copyStatus = data.withUnsafeBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            recordDecodeFailureOnQueue(reason: "block-buffer copy failed (\(copyStatus))")
            return
        }

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
            recordDecodeFailureOnQueue(reason: "sample-buffer create failed (\(sampleStatus))")
            return
        }

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
            recordDecodeFailureOnQueue(
                reason: "DecodeFrame failed status=\(decodeStatus) (isKeyframe=\(isKeyframe), \(data.count)B)")
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
                // Runs on VideoToolbox's own thread; bookkeeping hops to `queue`.
                if status != noErr {
                    decoder.queue.async {
                        decoder.recordDecodeFailureOnQueue(reason: "output callback reported status=\(status)")
                    }
                    return
                }
                guard let imageBuffer = imageBuffer else {
                    decoder.queue.async {
                        decoder.recordDecodeFailureOnQueue(reason: "output callback got nil imageBuffer")
                    }
                    return
                }
                decoder.onDecodedFrame?(imageBuffer)
                if decoder.episodeActive.withLock({ $0 }) {
                    decoder.queue.async { decoder.recordDecodeSuccessOnQueue() }
                }
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
            isRebuildingSession = false
        } else {
            logger.log("VideoDecoder: failed to create decompression session (\(status))")
            if isRebuildingSession {
                // Mid-session rebuild failure: the ladder keeps escalating.
                // Firing `onDecodeFailure` would trigger a nonsensical
                // codec-unsupported alert on a stream that decoded fine.
                return
            }
            if let codec = currentCodec, !didReportDecodeFailure {
                didReportDecodeFailure = true
                onDecodeFailure?(codec)
            }
        }
    }

    func shutdown() {
        // Drain in-flight async decodes BEFORE invalidating. VT's Invalidate
        // doesn't wait for submitted frames; a late callback could retain a
        // CVPixelBuffer whose backing is gone and SIGSEGV the caller.
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

// MARK: - Logger

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[VideoDecoder] \(message)")
    }
}
