import FFmpegKit
import Foundation
import PortalCaptureKit
import TailscreenProtocol
import TailscreenSharer

/// A Linux `CaptureEncoding` backend built on the ScreenCast portal: PipeWire
/// frames into a libavcodec encoder, producing the AVCC access units the
/// sharer fans out.
///
/// The third sibling of macOS's `HelperScreenCapture`, Linux's
/// `X11CaptureEncoder` and Windows' `WGCCaptureEncoder`. Everything above it —
/// admission, RTP fan-out, NACK/FEC, congestion control — is the portable
/// `TailscaleScreenShareServer`, unchanged.
///
/// **What it adds over `X11CaptureEncoder`** is everything the X11 path
/// structurally cannot do: native Wayland surfaces, a single window, a single
/// application. That is the reason this exists; it is not a second way to do
/// the same job.
///
/// **It is constructed against an already-negotiated session, not a
/// selection.** Same shape as the Windows backend taking an already-picked
/// `WGC.CaptureItem`, and for a sharper reason: negotiating raises a consent
/// dialog. The host consents once, holds the `PortalSession`, and the capture
/// factory closes over it — which is what makes the server's restart budget
/// safe to use. A backend that renegotiated on restart would answer a dropped
/// PipeWire connection by putting a dialog in front of somebody who is already
/// mid-share.
///
/// It takes a **closure returning a fresh PipeWire descriptor**, not the
/// `PortalSession` itself, and that is deliberate: a session owns a private
/// D-Bus connection libdbus expects to be driven from ONE thread, while
/// `start()` is called by the server from whichever thread it likes. Handing
/// over a closure leaves the threading discipline where the session actually
/// lives — in the host — instead of spreading it across a seam. It also keeps
/// this type free of any D-Bus concept at all.
///
/// `selectionData` still arrives and is still read: it carries the quality
/// knobs. Its `kind` is *not* checked, because unlike the other two backends
/// the portal genuinely can serve every kind — which one the user got is
/// something the portal's own picker decided, not something this side chooses.
///
/// **Scope.** Not covered here:
/// - System-audio capture, so `setAudioEnabled` is a no-op and
///   `onAudioAccessUnit` never fires. Viewer voice is unaffected; that path
///   does not come through here.
/// - `onPreviewImage`, which carries *encoded* image bytes because the mac
///   helper is a separate process with ImageIO on the far side. Raw pixels go
///   up through `onPreviewThumbnail` instead, as on the other two non-mac
///   backends.
/// - Multiple streams. The portal can hand back several; this takes the one it
///   was constructed with. Sharing two monitors as one share is a separate
///   piece of work, not a flag.
public final class PortalCaptureEncoder: CaptureEncoding, @unchecked Sendable {
    // MARK: CaptureEncoding callbacks

    public var onAccessUnit: ((Data, Bool) -> Void)?
    public var onAudioAccessUnit: ((Data) -> Void)?
    public var onParameterSets: ((CodecParameterSets) -> Void)?
    public var onEncoderResolution: ((Int, Int) -> Void)?
    public var onPreviewImage: ((Data) -> Void)?
    public var onUnexpectedExit: ((String) -> Void)?
    public var onUserStopped: (() -> Void)?
    public var onActivity: (() -> Void)?

    // MARK: Preview

    /// The sharer's own "this is what they can see" thumbnail, at most once a
    /// second (`ThumbnailScaler.intervalNs`).
    ///
    /// Not part of `CaptureEncoding` — see `onPreviewImage` above. Attached in
    /// the host's capture factory, so a restart's fresh backend keeps
    /// publishing.
    ///
    /// **Fires on PipeWire's thread**, from inside `ingest`. That thread must
    /// not be blocked, which is why this is throttled to once a second and
    /// scales straight out of the frame it was already handed rather than
    /// keeping a copy for someone else to scale later: one pass over pixels
    /// that are already in cache, next to the BGRA→I420 conversion that runs
    /// on every frame and costs more.
    public var onPreviewThumbnail: ((ThumbnailScaler.Thumbnail) -> Void)?

    public enum StartError: Error, CustomStringConvertible {
        case malformedSelection
        case captureUnavailable(String)
        case encoderUnavailable(String)

        public var description: String {
            switch self {
            case .malformedSelection: return "could not decode the picker selection"
            case .captureUnavailable(let message):
                return "the ScreenCast portal stream would not open: \(message)"
            case .encoderUnavailable(let message): return "no usable video encoder: \(message)"
            }
        }
    }

    /// Encoders tried in order until one opens.
    ///
    /// Software only, for the same reason as the other two backends: the
    /// hardware encoders libavcodec advertises consume *hardware* frames, which
    /// means an `AVHWFramesContext` and a per-frame upload this software-plane
    /// path does not do — so naming one here picks an encoder that then fails
    /// `avcodec_open2` on any machine without the matching device.
    ///
    /// There is a real opportunity here that the X11 path does not have: a
    /// PipeWire stream can carry DMA-BUF frames that are already on the GPU, so
    /// a future hardware path could skip the download entirely. That is
    /// separate work, and it starts with the `SPA_PARAM_BUFFERS_dataType`
    /// constraint this package currently sets to exclude exactly those buffers.
    public static let defaultH264Encoders = ["libx264", "libopenh264"]
    public static let defaultHEVCEncoders = ["libx265"]

    /// Opens a fresh PipeWire descriptor on the host's already-consented
    /// session. Called once per `start`, including after a restart — which is
    /// why it is a closure and not a value: `PortalStream` takes ownership of
    /// the descriptor, so a second start needs a second one.
    ///
    /// The host is responsible for calling this on whatever thread owns its
    /// D-Bus connection.
    private let openFileDescriptor: @Sendable () throws -> Int32
    private let nodeID: UInt32

    private let lock = NSLock()
    private var stream: PortalStream?
    private var encoder: FFmpeg.VideoEncoder?
    private var thread: Thread?
    private var running = false
    private var targetFPS = 30
    private var sentParameterSets = false
    private var keyframePending = false

    /// The double-buffered hand-off from PipeWire's thread to the encode
    /// thread. Its own type because it is the only real concurrency here and
    /// the only part of this file with a deterministic test — see
    /// `FrameHandoff`.
    private var handoff: FrameHandoff?

    /// Set by the frame callback when the stream's geometry stopped matching
    /// the encoder; acted on by the encode thread, because `avcodec_open2` on
    /// PipeWire's thread would stall the whole graph.
    private var rebuildRequest: (width: Int, height: Int)?
    private var lastRebuildNs: UInt64?
    /// When the last preview thumbnail was produced. Read and written only
    /// on PipeWire's thread, but under the lock like everything else here —
    /// the cost is a few instructions and the alternative is a field whose
    /// thread confinement is a comment rather than a fact.
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
    ///     already-negotiated session. **Consent has already been given**;
    ///     this backend never raises a dialog.
    public init(nodeID: UInt32, openFileDescriptor: @escaping @Sendable () throws -> Int32) {
        self.nodeID = nodeID
        self.openFileDescriptor = openFileDescriptor
    }

    deinit {
        // Synchronous only — no Task capturing self after deinit has begun.
        lock.lock()
        running = false
        lock.unlock()
    }

    // MARK: Lifecycle

    public func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws {
        // Decoded for its quality knobs. The `kind` is deliberately not
        // policed: see the type comment.
        guard (try? JSONDecoder().decode(PickerSelection.self, from: selectionData)) != nil else {
            throw StartError.malformedSelection
        }

        let fps = qualityEnv[QualitySettings.fpsCapEnvKey].flatMap(Int.init) ?? 30
        let hevc =
            !forceH264 && qualityEnv[QualitySettings.codecPrefEnvKey] == VideoCodec.hevc.rawValue

        lock.lock()
        targetFPS = fps
        sessionFPS = fps
        wantHEVC = hevc
        bitrateCeiling = qualityEnv[QualitySettings.maxBitrateEnvKey].flatMap(Int.init)
        currentBitrate = nil
        sentParameterSets = false
        // A viewer that connects before the GOP backstop fires has nothing to
        // decode, so the first frame out is always an IDR.
        keyframePending = true
        encoder = nil
        handoff = nil
        rebuildRequest = nil
        lastRebuildNs = nil
        lastPreviewNs = nil
        running = true
        lock.unlock()

        // Ownership of this descriptor passes to PortalStream, including when
        // its initializer throws — so there is nothing to close on the error
        // path here.
        let fileDescriptor: Int32
        do {
            fileDescriptor = try openFileDescriptor()
        } catch {
            lock.withLock { running = false }
            throw StartError.captureUnavailable("\(error)")
        }

        let opened: PortalStream
        do {
            opened = try PortalStream(
                fileDescriptor: fileDescriptor, nodeID: nodeID,
                onFrame: { [weak self] frame in self?.ingest(frame) },
                onState: { [weak self] state in self?.handle(state) })
        } catch {
            lock.withLock { running = false }
            throw StartError.captureUnavailable("\(error)")
        }

        lock.lock()
        stream = opened
        lock.unlock()

        // The encoder is NOT opened here. Its geometry comes from the
        // negotiated PipeWire format, and that is not known until the first
        // frame arrives — the portal's own reported size is advisory (see
        // `PortalSession.Stream`). So the first frame builds it, through the
        // same rebuild path a later resize uses, and `onEncoderResolution`
        // fires from there rather than from `start`.
        let captureThread = Thread { [weak self] in self?.captureLoop() }
        captureThread.name = "PortalCaptureEncoder"
        captureThread.start()
        lock.lock()
        thread = captureThread
        lock.unlock()
    }

    public func stop() async {
        // `withLock` rather than lock()/unlock(): the bare calls are
        // unavailable from an async context, since nothing stops the task
        // suspending while holding it and resuming on another thread.
        let wasRunning = lock.withLock {
            let was = running
            running = false
            return was
        }
        guard wasRunning else { return }
        // Release the stream first. Its deinit stops PipeWire's thread before
        // returning, which is what guarantees no frame callback is in flight
        // by the time the buffers go away.
        lock.withLock { stream = nil }
        try? await Task.sleep(for: .milliseconds(300))
        lock.withLock {
            encoder = nil
            thread = nil
            handoff = nil
        }
    }

    // MARK: Congestion levers

    public func requestKeyframe() {
        lock.withLock { keyframePending = true }
    }

    public func setBitrate(_ bps: Int) {
        let encoder = lock.withLock { () -> FFmpeg.VideoEncoder? in
            // Remembered so a rebuild picks up where the controller left off
            // rather than resetting to the formula figure — on this backend a
            // rebuild happens whenever a shared window is resized, which is
            // far too often to be discarding congestion state.
            currentBitrate = bps
            return self.encoder
        }
        encoder?.setBitrate(bps)
    }

    /// No system-audio capture here, so the emission latch has nothing to
    /// gate. An explicit no-op rather than an omission, so the server's
    /// re-send after every backend restart is harmless.
    public func setAudioEnabled(_ on: Bool) {}

    /// Retune the capture rate. Only the *pacing* changes: the encoder keeps
    /// its time base, which is fine because RTP timestamps come from the
    /// server's clock rather than encoder PTS.
    public func setFrameInterval(_ fps: Int) {
        guard fps > 0 else { return }
        lock.withLock { targetFPS = fps }
    }

    // MARK: PipeWire callbacks

    /// Route a stream condition through the tested plan.
    ///
    /// The translation below is the only part not covered by
    /// `PortalCapturePlanTests`, and it is four lines with no arithmetic
    /// precisely so that it can't be the part that is wrong.
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
    /// pointer is valid only for this call, so the conversion has to happen
    /// here; the *encode* deliberately does not, because a thread that stops
    /// servicing the graph is one PipeWire starts dropping buffers on. The
    /// lock is taken twice for a few instructions each and never held across
    /// the conversion itself.
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
            // Still proof of life: a frame we chose not to encode is a
            // healthy backend, not a wedged one.
            onActivity?()
            return
        case .rebuildEncoder(let width, let height):
            // Hand the work to the encode thread. `avcodec_open2` here would
            // stall the graph for as long as x264 takes to initialize.
            lock.withLock { rebuildRequest = (width, height) }
            onActivity?()
            return
        case .encode:
            break
        }

        guard let handoff = lock.withLock({ self.handoff }) else { return }
        // The conversion runs inside `write`, which holds no lock across it —
        // blocking PipeWire's thread is what this whole design avoids.
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
    ///
    /// Deliberately reads `frame` rather than the converted planes: the BGRA is
    /// right there and still valid for the length of this call, so the preview
    /// costs one extra pass over pixels already in cache instead of a
    /// round trip back out of I420.
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

    /// Paces and encodes. Owns the encoder, and is the only caller of
    /// `FrameHandoff.publish` — which is what lets that type keep the encoder
    /// off any buffer PipeWire's thread is mid-conversion into.
    ///
    /// It also owns every `avcodec_open2`: rebuilding on PipeWire's thread
    /// would stall the graph for as long as x264 takes to initialize, which on
    /// a window being dragged is exactly when the desktop can least afford it.
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

            let owedKeyframe = lock.withLock { () -> Bool in
                let owed = keyframePending
                keyframePending = false
                return owed
            }
            let (handoff, encoder) = lock.withLock { (self.handoff, self.encoder) }
            // Publish a completed frame, if PipeWire finished one and is not
            // in the middle of the next.
            let published = handoff?.publish()
            // `hasFrame` gates the still-screen keyframe path: without it a
            // PLI arriving before the first real frame would encode the
            // initial grey buffer and send it to viewers as the sharer's
            // screen.
            let haveNew = published?.isNew ?? false
            let planes = (handoff?.hasFrame ?? false) ? published?.planes : nil

            // Encode when there is something new, OR when a keyframe is owed
            // and there is a previous frame to make one from. That second case
            // is not an optimisation: a compositor delivers nothing while the
            // screen is still, so a viewer that joins — or PLIs — during a
            // motionless moment would otherwise wait for the user to move
            // something before it could decode anything at all.
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
                    // An encode that failed did not produce the keyframe
                    // somebody is waiting for, so put the request back.
                    if owedKeyframe { lock.withLock { keyframePending = true } }
                }
            } else if owedKeyframe {
                lock.withLock { keyframePending = true }
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds &- frameStart
            let interval = UInt64(1_000_000_000 / max(1, fps))
            if elapsed < interval {
                Thread.sleep(forTimeInterval: Double(interval - elapsed) / 1_000_000_000)
            }
        }
    }

    /// Open an encoder at `width`x`height`, replacing any existing one.
    ///
    /// Called for the first frame and for every accepted resize. Re-emitting
    /// `onParameterSets` and `onEncoderResolution` is not a special case: the
    /// seam documents parameter sets as "once per encoder configuration", and
    /// the server's anchor handler already compares against its last inputs and
    /// re-anchors only when they genuinely changed.
    private func rebuild(width: Int, height: Int) {
        let (hevc, fps, ceiling, previousBitrate) = lock.withLock {
            (wantHEVC, sessionFPS, bitrateCeiling, currentBitrate)
        }

        let codec: VideoCodec = hevc ? .hevc : .h264
        let formulaBitrate = EncoderTuning.computeBitrate(
            width: width, height: height, fps: fps,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: codec))
        // The controller's current figure wins if it has one: this backend
        // rebuilds whenever a shared window is resized, and re-anchoring to the
        // formula each time would undo every cut the congestion controller had
        // made on a link that has not changed.
        let anchored = previousBitrate ?? min(formulaBitrate, ceiling ?? formulaBitrate)
        let bitrate = min(anchored, ceiling ?? anchored)

        let names = hevc ? Self.defaultHEVCEncoders : Self.defaultH264Encoders
        var opened: FFmpeg.VideoEncoder?
        var attempts: [String] = []
        for name in names where FFmpeg.isEncoderAvailable(name) {
            do {
                // `hevc ? .hevc : .h264` rather than the `codec` above: that
                // one is TailscreenProtocol's `VideoCodec`, which the bitrate
                // formula takes, and this one is FFmpegKit's own enum.
                opened = try FFmpeg.VideoEncoder(
                    codec: hevc ? .hevc : .h264, width: width, height: height,
                    fps: fps, bitrate: bitrate, encoderName: name)
                break
            } catch {
                attempts.append("\(name): \(error)")
            }
        }
        guard let opened else {
            let detail =
                attempts.isEmpty
                ? "none of \(names) present in this libavcodec build"
                : attempts.joined(separator: "; ")
            lock.withLock { running = false }
            onUnexpectedExit?("permanent: \(StartError.encoderUnavailable(detail))")
            return
        }

        lock.withLock {
            encoder = opened
            // Both buffers are re-made at the new geometry. Keeping the old
            // front would leave the encoder reading planes sized for the
            // previous resolution on the very next pass.
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

    /// Hand the codec parameter sets up once per encoder configuration.
    ///
    /// They stay in-band on every keyframe regardless — that is what lets a
    /// viewer join mid-stream. This callback exists because the server caches
    /// the codec from it, and because the ordering contract (`onParameterSets`
    /// before `onEncoderResolution`) drives its adaptive-bitrate anchor.
    private func emitParameterSets(from avcc: Data) {
        let (already, isHEVC) = lock.withLock { (sentParameterSets, encoder?.codec == .hevc) }
        guard !already, let handler = onParameterSets else { return }
        guard let annexB = NALUnit.avccToAnnexB(avcc) else { return }
        guard
            let sets = ParameterSetExtraction.parameterSets(
                fromAnnexBNALs: NALUnit.annexBNALs(annexB),
                codec: isHEVC ? .hevc : .h264)
        else { return }
        lock.withLock { sentParameterSets = true }
        handler(sets)
    }
}
