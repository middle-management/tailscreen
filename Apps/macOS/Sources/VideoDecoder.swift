import AppKit
import CoreMedia
import CoreVideo
import TailscaleKit
import VideoToolbox
import os

/// One rung of the viewer's consecutive-decode-failure escalation ladder.
/// Produced by `VideoDecoder.decodeRecoveryAction(consecutiveFailures:
/// alreadyFired:)` — `>=` thresholds plus a per-episode fired-rung latch, so
/// each rung fires once per failing episode even if the counter ever skips a
/// value; counter and latches reset on the next successfully decoded frame.
enum DecodeRecoveryAction: Hashable, Sendable {
    /// Ask the sharer for a fresh keyframe — a new IDR often un-wedges a
    /// decoder whose reference state was corrupted by loss, and it's cheap.
    case requestKeyframe
    /// Invalidate and rebuild the decompression session from the installed
    /// format description (handled inside `VideoDecoder` itself).
    case recreateSession
    /// Show a "Connection degraded" indication — the stream has been dead
    /// for a second or two of wall-clock video.
    case signalDegraded
    /// Surface the stall through the app's alert path.
    case surfaceError
}

final class VideoDecoder: @unchecked Sendable {
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    /// Fires (once per codec) when VideoToolbox can't build a decompression
    /// session — almost always an HEVC stream arriving on a Mac without HEVC
    /// decode support. Without this the viewer sits on a silent black screen;
    /// the client uses it to surface an error and ask the sharer to fall back
    /// to H.264. Called on the decoder's serial `queue`.
    var onDecodeFailure: ((VideoCodec) -> Void)?

    /// Fires on the decoder's serial `queue` for every per-frame decode
    /// failure (block-/sample-buffer creation, `DecodeFrame` errors, and bad
    /// output-callback statuses). The client counts these into the stats
    /// overlay.
    var onFrameDecodeFailed: (() -> Void)?

    /// Fires on the decoder's serial `queue` when the consecutive-failure
    /// count crosses an escalation threshold — see `DecodeRecoveryAction`.
    /// `.recreateSession` has already been handled internally by the time
    /// this fires; the other rungs are the client's job.
    var onRecoveryAction: ((DecodeRecoveryAction) -> Void)?

    /// Fires on the decoder's serial `queue` when a frame decodes
    /// successfully after the ladder had reached `.signalDegraded`, so the
    /// client can clear the degraded indication.
    var onRecovered: (() -> Void)?

    private let queue = DispatchQueue(label: "com.tailscreen.decoder")
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    /// Codec of the currently-installed parameter sets, so a session-create
    /// failure can report *which* codec the viewer couldn't decode.
    private var currentCodec: VideoCodec?
    /// Latched after we've reported a decode failure for `currentCodec`, so a
    /// black-screened viewer doesn't fire `onDecodeFailure` once per frame.
    /// Reset when the installed codec changes (e.g. the sharer falls back).
    private var didReportDecodeFailure = false
    /// Consecutive per-frame decode failures. Mutated only on `queue`;
    /// reset by the first successful frame delivery. Drives the escalation
    /// ladder below.
    private var consecutiveFailures = 0
    /// Rungs that already fired during the current failing episode. Paired
    /// with the `>=` thresholds in `decodeRecoveryAction` so each rung fires
    /// once per episode even when the counter skips a value. Mutated only on
    /// `queue`; cleared with the counter on the first successful frame.
    private var firedRecoveryActions: Set<DecodeRecoveryAction> = []
    /// True between `.recreateSession` tearing the session down and the next
    /// successful rebuild. While set, a `createDecompressionSession` failure
    /// only logs — `onDecodeFailure` (the codec-unsupported path, which the
    /// client answers with CODEC_NO and a "lacks hardware decode" alert) is
    /// reserved for the *initial* session creation; mid-session rebuild
    /// failures keep counting through the ladder instead. Mutated only on
    /// `queue`.
    private var isRebuildingSession = false
    /// True while a failing episode is live: set by the first counted
    /// failure, cleared by the success-path reset. The VT output callback
    /// reads it to skip dispatching a per-frame `recordDecodeSuccessOnQueue`
    /// hop on the healthy path — at 60 fps that async would otherwise write
    /// 0 over 0 all day. Locked because the callback reads on VideoToolbox's
    /// thread while the decoder's serial `queue` writes.
    private let episodeActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let logger = TSLogger()

    // MARK: - Decode-failure escalation ladder

    /// Failures before the first rung: ask the sharer for a keyframe.
    static let requestKeyframeFailureThreshold = 5
    /// Failures before the decompression session is torn down and rebuilt.
    static let recreateSessionFailureThreshold = 30
    /// Failures before the degraded indication (~1.5–3 s of dead video at
    /// 30–60 fps).
    static let signalDegradedFailureThreshold = 90
    /// Failures before the stall is surfaced as an alert (~5–10 s).
    static let surfaceErrorFailureThreshold = 300

    /// Pure escalation decision (CI-tested by `DecodeRecoveryDecisionTests`):
    /// the highest rung whose threshold `consecutiveFailures` meets or
    /// exceeds — returned only if it hasn't fired yet this episode, nil once
    /// it has. `>=` plus the `alreadyFired` latch (instead of exact `==`
    /// matching) keeps the ladder moving even when the counting is imperfect
    /// and a threshold value gets skipped. Rungs below the highest met one
    /// are superseded, never fired late, so an episode's rungs always fire
    /// in order and at most once. The caller resets its latch set along with
    /// the counter on the first successful frame.
    static func decodeRecoveryAction(
        consecutiveFailures: Int,
        alreadyFired: Set<DecodeRecoveryAction>
    ) -> DecodeRecoveryAction? {
        let rungsHighestFirst: [(threshold: Int, action: DecodeRecoveryAction)] = [
            (surfaceErrorFailureThreshold, .surfaceError),
            (signalDegradedFailureThreshold, .signalDegraded),
            (recreateSessionFailureThreshold, .recreateSession),
            (requestKeyframeFailureThreshold, .requestKeyframe)
        ]
        for rung in rungsHighestFirst where consecutiveFailures >= rung.threshold {
            if alreadyFired.contains(rung.action) { return nil }
            return rung.action
        }
        return nil
    }

    /// Record one per-frame decode failure and act on any escalation
    /// threshold it crosses. `.recreateSession` is handled here (the session
    /// is this class's own state); every rung is also forwarded to
    /// `onRecoveryAction` so the client can request keyframes / update UI.
    /// `reason` feeds a throttled log line — first failure of the run, then
    /// every 60th, matching the client's AU-log idiom — so a stalled 60 fps
    /// stream doesn't emit 60 lines/s. Must run on `queue`.
    private func recordDecodeFailureOnQueue(reason: String) {
        consecutiveFailures += 1
        episodeActive.withLock { $0 = true }
        if consecutiveFailures == 1 || consecutiveFailures % 60 == 0 {
            logger.log("VideoDecoder: decode failure #\(consecutiveFailures): \(reason)")
        }
        onFrameDecodeFailed?()
        let decision = Self.decodeRecoveryAction(
            consecutiveFailures: consecutiveFailures, alreadyFired: firedRecoveryActions)
        guard let action = decision else { return }
        firedRecoveryActions.insert(action)
        logger.log("VideoDecoder: \(consecutiveFailures) consecutive decode failures — escalating to \(action)")
        if action == .recreateSession {
            recreateSessionOnQueue()
        }
        onRecoveryAction?(action)
    }

    /// Reset the failure run after a successful frame delivery; fires
    /// `onRecovered` when the run had already fired the degraded rung so the
    /// client can clear the indication. Must run on `queue`.
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

    /// Tear the wedged decompression session down so the next `decode`
    /// lazily rebuilds it from the installed `formatDescription`. Reuses
    /// `shutdown()`'s drain-before-invalidate ordering (see that method's
    /// comment for the teardown race it prevents) but keeps the format
    /// description and callbacks — the stream itself is still live. Must
    /// run on `queue`.
    private func recreateSessionOnQueue() {
        guard let session = session else { return }
        logger.log("VideoDecoder: recreating decompression session after persistent decode failures")
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        // The next create is a mid-session rebuild: if it fails, keep
        // counting through the ladder instead of firing the
        // codec-unsupported path (see `isRebuildingSession`).
        isRebuildingSession = true
    }

    /// Install codec parameter sets. The server sends these before any
    /// frames, and re-sends them on every IDR so late joiners can recover
    /// without guessing. Switching codecs (e.g. server reconnects with a
    /// different codec) tears down the session and rebuilds.
    func setParameterSets(_ params: CodecParameterSets) {
        queue.async { [weak self] in
            self?.applyParameterSets(params)
        }
    }

    /// Decode one AVCC-formatted access unit (length-prefixed NAL units).
    /// A frame arriving before parameter sets are installed counts as a
    /// decode failure so the escalation ladder can request the keyframe
    /// that carries them in-band.
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

        // New codec installed (e.g. sharer fell back HEVC→H.264): clear the
        // failure latch so a fresh codec gets a fresh chance to be reported.
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
        // A fresh format description means the next session create is the
        // *initial* create for that stream config, not a mid-episode
        // rebuild — restore the codec-unsupported reporting path.
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
        // Both early-outs below MUST count as failures. A silent return
        // here froze the ladder at the recreate rung: `.recreateSession`
        // nils the session, and if the rebuild kept failing the counter
        // pinned at the recreate threshold and the degraded/alert rungs
        // never fired.
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
                // The callback runs on VideoToolbox's own thread; the
                // failure/success bookkeeping hops to the decoder's serial
                // `queue` where `consecutiveFailures` lives.
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
                // Only pay the queue hop while a failing episode is live —
                // on the healthy path the reset would write 0 over 0 at
                // 60 fps for nothing.
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
                // Mid-session rebuild failure: the caller's session guard
                // counts it and the ladder keeps escalating. Firing
                // `onDecodeFailure` here would trigger the codec-unsupported
                // path (CODEC_NO + "lacks hardware decode" alert), which is
                // nonsensical mid-session on a stream that decoded fine.
                return
            }
            if let codec = currentCodec, !didReportDecodeFailure {
                didReportDecodeFailure = true
                onDecodeFailure?(codec)
            }
        }
    }

    func shutdown() {
        // Drain in-flight async decodes BEFORE invalidating. VT's
        // Invalidate doesn't wait for submitted frames to finish; the
        // output callback can fire after Invalidate returns, retain a
        // CVPixelBuffer whose backing is gone, and SIGSEGV the caller
        // (e.g. the VTVideoDecoderAdapter's onDecodedFrame boxing a dead
        // pointer when the viewer's window-close button triggers disconnect
        // mid-decode).
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
