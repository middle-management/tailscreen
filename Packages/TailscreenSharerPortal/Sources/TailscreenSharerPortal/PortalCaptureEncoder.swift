import FFmpegKit
import Foundation
import PortalCaptureKit
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerFFmpegBase

/// A Linux `CaptureEncoding` backend built on the ScreenCast portal: PipeWire
/// frames into a libavcodec encoder, producing the AVCC access units the
/// sharer fans out. The third sibling of macOS's `HelperScreenCapture`,
/// Linux's `X11CaptureEncoder` and Windows' `WGCCaptureEncoder`; adds what
/// X11 structurally can't — native Wayland surfaces, single window/app.
///
/// **Constructed against an already-negotiated session, not a selection** —
/// negotiating raises a consent dialog, so the host consents once and the
/// capture factory closes over the `PortalSession`, keeping the server's
/// restart budget dialog-free.
///
/// Takes a **closure returning a fresh PipeWire descriptor**, not the
/// `PortalSession` itself: the session's D-Bus connection must be driven from
/// ONE thread, while `start()` can be called from any thread. The closure
/// keeps that threading discipline in the host and keeps this type free of
/// any D-Bus concept.
///
/// `selectionData`'s `kind` is deliberately not checked — unlike the other
/// backends, the portal can serve every kind; the portal's own picker decided
/// which one the user got.
///
/// **Scope.** Not covered: system-audio capture; `onPreviewImage` (raw
/// pixels go through `onPreviewThumbnail` instead, as on the other non-mac
/// backends); multiple streams (takes the one it was constructed with).
///
/// Future hardware opportunity X11 doesn't have: PipeWire can carry DMA-BUF
/// frames already on the GPU — separate work, starting with the
/// `SPA_PARAM_BUFFERS_dataType` constraint this package currently sets to exclude them.
public final class PortalCaptureEncoder: FFmpegCaptureEncoderBase, CaptureEncoding, @unchecked Sendable {
    // MARK: Preview

    /// The sharer's own "this is what they can see" thumbnail, at most once a
    /// second. Not part of `CaptureEncoding` — see the type comment.
    ///
    /// **Fires on PipeWire's thread**, which must not be blocked — throttled
    /// to once a second and scaled straight out of the frame already handed,
    /// rather than keeping a copy for later.
    public var onPreviewThumbnail: ((ThumbnailScaler.Thumbnail) -> Void)?

    /// Opens a fresh PipeWire descriptor on the host's already-consented
    /// session. A closure, not a value, because `PortalStream` takes
    /// ownership of the descriptor, so a second start needs a second one.
    /// The host must call this on whatever thread owns its D-Bus connection.
    private let openFileDescriptor: @Sendable () throws -> Int32
    private let nodeID: UInt32

    private var stream: PortalStream?

    /// The double-buffered hand-off from PipeWire's thread to the encode
    /// thread — see `FrameHandoff`.
    private var handoff: FrameHandoff?

    /// Set by the frame callback when the stream's geometry stopped matching
    /// the encoder; acted on by the encode thread, since `avcodec_open2` on
    /// PipeWire's thread would stall the whole graph.
    private var rebuildRequest: (width: Int, height: Int)?
    private var lastRebuildNs: UInt64?
    /// Read/written only on PipeWire's thread, but still under the lock like
    /// everything else here, for a few instructions' cost.
    private var lastPreviewNs: UInt64?

    /// Codec choice, resolved at `start` and reused by every rebuild so a
    /// resize cannot silently switch codecs mid-share.
    private var wantHEVC = false
    private var sessionFPS = 30
    private var bitrateCeiling: Int?
    /// The bitrate the congestion controller last asked for, so a rebuild does
    /// not throw away its decisions and jump back to the formula figure.
    private var currentBitrate: Int?

    /// - Parameters:
    ///   - nodeID: which of the session's streams to capture.
    ///   - openFileDescriptor: opens a PipeWire descriptor on the host's
    ///     already-negotiated session — this backend never raises a dialog.
    public init(nodeID: UInt32, openFileDescriptor: @escaping @Sendable () throws -> Int32) {
        self.nodeID = nodeID
        self.openFileDescriptor = openFileDescriptor
        super.init()
    }

    // MARK: Lifecycle

    public func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws {
        // Decoded for its quality knobs. The `kind` is deliberately not
        // policed: see the type comment.
        guard (try? JSONDecoder().decode(PickerSelection.self, from: selectionData)) != nil else {
            throw StartError.malformedSelection
        }

        let settings = EncodeSettings(forceH264: forceH264, qualityEnv: qualityEnv)

        lock.lock()
        targetFPS = settings.fps
        sessionFPS = settings.fps
        wantHEVC = settings.wantHEVC
        bitrateCeiling = settings.bitrateCeiling
        currentBitrate = nil
        sentParameterSets = false
        keyframePending = true  // first frame out is always an IDR
        encoder = nil
        handoff = nil
        rebuildRequest = nil
        lastRebuildNs = nil
        lastPreviewNs = nil
        running = true
        lock.unlock()

        // Ownership passes to PortalStream, even when its init throws — so
        // nothing to close on the error path here.
        let fileDescriptor: Int32
        do {
            fileDescriptor = try openFileDescriptor()
        } catch {
            lock.withLock { running = false }
            throw StartError.captureUnavailable(
                "the ScreenCast portal stream would not open: \(error)")
        }

        let opened: PortalStream
        do {
            opened = try PortalStream(
                fileDescriptor: fileDescriptor, nodeID: nodeID,
                onFrame: { [weak self] frame in self?.ingest(frame) },
                onState: { [weak self] state in self?.handle(state) })
        } catch {
            lock.withLock { running = false }
            throw StartError.captureUnavailable(
                "the ScreenCast portal stream would not open: \(error)")
        }

        lock.lock()
        stream = opened
        lock.unlock()

        // The encoder is NOT opened here — its geometry comes from the
        // negotiated PipeWire format, unknown until the first frame arrives
        // (the portal's reported size is advisory). The first frame builds
        // it through the same rebuild path a later resize uses.
        startCaptureThread(named: "PortalCaptureEncoder") { [weak self] in self?.captureLoop() }
    }

    /// Release the stream first — its deinit stops PipeWire's thread before
    /// returning, guaranteeing no frame callback is in flight when buffers go away.
    override public func willStopBeforeSettle() {
        lock.withLock { stream = nil }
    }

    override public func releaseCaptureResourcesLocked() {
        handoff = nil
    }

    // MARK: Congestion levers

    override public func setBitrate(_ bps: Int) {
        let encoder = lock.withLock { () -> FFmpeg.VideoEncoder? in
            // Remembered so a rebuild (frequent — every window resize) picks
            // up where the controller left off rather than resetting to the formula figure.
            currentBitrate = bps
            return self.encoder
        }
        encoder?.setBitrate(bps)
    }

    // MARK: PipeWire callbacks

    /// Route a stream condition through the tested plan. The translation
    /// below is the only part not covered by `PortalCapturePlanTests`, kept
    /// to four lines with no arithmetic so it can't be the part that's wrong.
    private func handle(_ state: PortalStream.State) {
        let condition: PortalCapturePlan.Condition
        switch state {
        case .connecting: condition = .connecting
        case .streaming: condition = .streaming
        case .failed(let detail): condition = .failed(detail)
        case .ended(let detail): condition = .ended(detail)
        }

        switch PortalCapturePlan.action(for: condition) {
        case .ignore:
            return
        case .userStopped:
            lock.withLock { running = false }
            onUserStopped?()
        case .unexpectedExit(let reason):
            lock.withLock { running = false }
            onUnexpectedExit?(reason)
        }
    }

    /// Convert one PipeWire frame into the back buffer.
    ///
    /// **Runs on PipeWire's own thread, and must not block it.** The frame
    /// pointer is valid only for this call, so conversion happens here; the
    /// encode deliberately does not, since PipeWire drops buffers on a
    /// thread that stops servicing the graph.
    private func ingest(_ frame: PortalStream.Frame) {
        let now = DispatchTime.now().uptimeNanoseconds
        let decision = lock.withLock { () -> PortalCapturePlan.FrameAction? in
            guard running else { return nil }
            let geometry = handoff.map { (width: $0.width, height: $0.height) }
            return PortalCapturePlan.frameAction(
                frame: (width: frame.width, height: frame.height),
                encoder: geometry, lastRebuildNs: lastRebuildNs, nowNs: now)
        }
        guard let decision else { return }

        switch decision {
        case .drop:
            // Still proof of life: an unencoded frame is a healthy backend.
            onActivity?()
            return
        case .rebuildEncoder(let width, let height):
            // Hand to the encode thread — `avcodec_open2` here would stall the graph.
            lock.withLock { rebuildRequest = (width, height) }
            onActivity?()
            return
        case .encode:
            break
        }

        guard let handoff = lock.withLock({ self.handoff }) else { return }
        // `write` holds no lock across the conversion — blocking PipeWire's
        // thread is what this whole design avoids.
        handoff.write { planes in
            planes.y.withUnsafeMutableBufferPointer { y in
                planes.u.withUnsafeMutableBufferPointer { u in
                    planes.v.withUnsafeMutableBufferPointer { v in
                        guard let yBase = y.baseAddress, let uBase = u.baseAddress,
                            let vBase = v.baseAddress
                        else { return false }
                        return BGRAToI420.convert(
                            BGRAToI420.Source(
                                bgra: frame.bgra, stride: frame.stride,
                                width: planes.width, height: planes.height),
                            into: BGRAToI420.Planes(y: yBase, u: uBase, v: vBase))
                    }
                }
            }
        }
        publishPreview(frame: frame, nowNs: now)
        onActivity?()
    }

    /// Scale the frame just ingested into a preview, at most once a second.
    /// Reads `frame` (still valid, in cache) rather than the converted
    /// planes, avoiding a round trip back out of I420.
    private func publishPreview(frame: PortalStream.Frame, nowNs: UInt64) {
        guard let sink = onPreviewThumbnail else { return }
        let due = lock.withLock { () -> Bool in
            guard ThumbnailScaler.shouldCapture(lastCaptureNs: lastPreviewNs, nowNs: nowNs) else {
                return false
            }
            lastPreviewNs = nowNs
            return true
        }
        guard due,
            let thumbnail = ThumbnailScaler.thumbnail(
                bgra: frame.bgra, stride: frame.stride,
                width: frame.width, height: frame.height)
        else { return }
        sink(thumbnail)
    }

    // MARK: Encode loop

    /// Paces and encodes. Owns the encoder and is the only caller of
    /// `FrameHandoff.publish`. Also owns every `avcodec_open2` — rebuilding
    /// on PipeWire's thread would stall the graph, worst exactly while a
    /// window is being dragged.
    private func captureLoop() {
        while true {
            let (stillRunning, fps) = lock.withLock { (running, targetFPS) }
            guard stillRunning else { break }
            let frameStart = DispatchTime.now().uptimeNanoseconds

            if let request = lock.withLock({ () -> (width: Int, height: Int)? in
                defer { rebuildRequest = nil }
                return rebuildRequest
            }) {
                rebuild(width: request.width, height: request.height)
            }

            let owedKeyframe = takeOwedKeyframe()
            let (handoff, encoder) = lock.withLock { (self.handoff, self.encoder) }
            let published = handoff?.publish()
            // `hasFrame` gates the still-screen keyframe path: without it a
            // PLI before the first real frame would encode the initial grey
            // buffer and send it to viewers as the sharer's screen.
            let haveNew = published?.isNew ?? false
            let planes = (handoff?.hasFrame ?? false) ? published?.planes : nil

            // Encode when new, OR when a keyframe is owed and there's a
            // previous frame — a compositor delivers nothing on a still
            // screen, so a joining viewer would otherwise wait for motion.
            if let planes, let encoder, haveNew || owedKeyframe {
                if owedKeyframe { encoder.requestKeyframe() }
                do {
                    for accessUnit in try encoder.encode(
                        yPlane: planes.y, uPlane: planes.u, vPlane: planes.v)
                    {
                        if accessUnit.isKeyframe { emitParameterSets(from: accessUnit.data) }
                        onAccessUnit?(accessUnit.data, accessUnit.isKeyframe)
                    }
                } catch {
                    // Didn't produce the keyframe someone's waiting for — put it back.
                    if owedKeyframe { lock.withLock { keyframePending = true } }
                }
            } else if owedKeyframe {
                lock.withLock { keyframePending = true }
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds &- frameStart
            Self.paceFrame(elapsedNs: elapsed, fps: fps)
        }
    }

    /// Open an encoder at `width`x`height`, replacing any existing one.
    /// Called for the first frame and every accepted resize.
    private func rebuild(width: Int, height: Int) {
        let (hevc, fps, ceiling, previousBitrate) = lock.withLock {
            (wantHEVC, sessionFPS, bitrateCeiling, currentBitrate)
        }

        // The controller's current figure wins if it has one — re-anchoring
        // to the formula on every resize would undo its cuts on an
        // unchanged link.
        let anchored =
            previousBitrate
            ?? Self.anchoredBitrate(
                width: width, height: height, fps: fps, wantHEVC: hevc, ceiling: ceiling)
        let bitrate = min(anchored, ceiling ?? anchored)

        let opened: FFmpeg.VideoEncoder
        do {
            opened = try Self.openSoftwareEncoder(
                wantHEVC: hevc, width: width, height: height, fps: fps, bitrate: bitrate)
        } catch {
            lock.withLock { running = false }
            onUnexpectedExit?("permanent: \(error)")
            return
        }

        lock.withLock {
            encoder = opened
            if let handoff {
                handoff.resize(width: width, height: height)
            } else {
                handoff = FrameHandoff(width: width, height: height)
            }
            sentParameterSets = false
            keyframePending = true
            lastRebuildNs = DispatchTime.now().uptimeNanoseconds
        }
        onEncoderResolution?(width, height)
    }
}
