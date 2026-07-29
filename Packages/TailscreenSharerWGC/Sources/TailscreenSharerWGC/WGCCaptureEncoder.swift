import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import WGCCaptureKit

/// A Windows `CaptureEncoding` backend: Windows.Graphics.Capture into a
/// libavcodec encoder, producing the AVCC access units the sharer fans out.
///
/// The Windows counterpart of macOS's `HelperScreenCapture` and Linux's
/// `X11CaptureEncoder`, and structurally the latter — everything above it
/// (admission, RTP fan-out, NACK/FEC, congestion control) is the portable
/// `TailscaleScreenShareServer`, unchanged. This supplies pixels and honours
/// the three congestion levers.
///
/// **It is constructed with an already-picked target, not with an ID.** That
/// is the one real shape difference from the other two backends, and it comes
/// from the platform: a `GraphicsCaptureItem` is an opaque WinRT object with
/// no stable identifier to serialize and resolve later, the way a `CGWindowID`
/// or an X display string can be. So the host picks once, holds the item, and
/// the capture factory closes over it — which is also what makes a restart
/// re-target the same window without asking the user again, the invariant the
/// macOS helper gets from re-resolving its cached `PickerSelection`.
///
/// `selectionData` still arrives, and is still read: it carries the quality
/// knobs, and its `kind` is checked against what an item can actually be.
///
/// **Scope.** Display and single-window shares — which is the reason this is
/// built on WGC rather than DXGI Desktop Duplication, whose whole-output-only
/// model could answer only `.display`. Not covered:
/// - Multi-window application shares (`.application`). One item is one target;
///   an app share is a set. Rejected rather than silently widened to the
///   display, which would be a privacy failure rather than a missing feature.
/// - System-audio capture, so `setAudioEnabled` is a no-op and
///   `onAudioAccessUnit` never fires. Viewer voice is unaffected — that path
///   does not come through here.
/// - Preview thumbnails (`onPreviewImage` never fires).
/// - Cloaked Apps. Windows has no equivalent knob: `WDA_EXCLUDEFROMCAPTURE`
///   is set by a window's own owner, so a capturer cannot exclude someone
///   else's window under either capture API. `excludedBundleIDs` is ignored,
///   and the host must not offer the setting on this platform.
public final class WGCCaptureEncoder: CaptureEncoding, @unchecked Sendable {
    // MARK: CaptureEncoding callbacks

    public var onAccessUnit: ((Data, Bool) -> Void)?
    public var onAudioAccessUnit: ((Data) -> Void)?
    public var onParameterSets: ((CodecParameterSets) -> Void)?
    public var onEncoderResolution: ((Int, Int) -> Void)?
    public var onPreviewImage: ((Data) -> Void)?
    public var onUnexpectedExit: ((String) -> Void)?
    public var onUserStopped: (() -> Void)?
    public var onActivity: (() -> Void)?

    /// Per-stage timings, once a second. Not part of `CaptureEncoding` — it is
    /// this backend's own diagnostic, and the question it answers ("which of
    /// capture, convert and encode is the slow one") is one a viewer's stats
    /// overlay structurally cannot: from the far end a slow sharer and a quiet
    /// screen look identical.
    public var onTimings: ((CaptureTimings) -> Void)?

    public enum StartError: Error, CustomStringConvertible {
        case unsupportedSelection(String)
        case malformedSelection
        case captureUnavailable(String)
        case encoderUnavailable(String)

        public var description: String {
            switch self {
            case .unsupportedSelection(let kind):
                return
                    "a capture item is one display or one window; \(kind) shares are not supported here"
            case .malformedSelection: return "could not decode the picker selection"
            case .captureUnavailable(let message): return "screen capture unavailable: \(message)"
            case .encoderUnavailable(let message): return "no usable video encoder: \(message)"
            }
        }
    }

    /// Encoders tried in order until one opens.
    ///
    /// Software only, for the same reason as the Linux backend: `h264_qsv`,
    /// `h264_nvenc` and `h264_amf` are present in most libavcodec builds and
    /// `avcodec_find_encoder_by_name` finds them, but they consume *hardware*
    /// frames — using one means an `AVHWFramesContext` and a per-frame upload
    /// this software-plane path does not do, so naming one here would pick an
    /// encoder that then fails to open on any machine without the matching
    /// device. Hardware encode is worth having and is separate work.
    public static let defaultH264Encoders = ["libx264", "libopenh264"]
    public static let defaultHEVCEncoders = ["libx265"]

    private let item: WGC.CaptureItem
    private let lock = NSLock()
    private var session: WGC.Session?
    private var encoder: FFmpeg.VideoEncoder?
    private var thread: Thread?
    private var running = false
    /// Target capture rate, retuned live by `setFrameInterval` — the fps
    /// ladder's second congestion lever.
    private var targetFPS = 30
    private var sentParameterSets = false
    /// Set by `requestKeyframe` and consumed by the capture loop. Needed
    /// because a keyframe may have to be produced when no NEW frame is
    /// arriving; see `captureLoop`.
    private var keyframePending = false

    /// - Parameter item: the target the user already chose, via
    ///   ``WGC/CaptureItem/pick(ownerWindow:)`` or one of the no-UI
    ///   constructors.
    public init(item: WGC.CaptureItem) {
        self.item = item
    }

    deinit {
        // Synchronous only — no Task capturing self after deinit has begun.
        lock.lock()
        running = false
        lock.unlock()
    }

    // MARK: Lifecycle

    public func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws {
        guard let selection = try? JSONDecoder().decode(PickerSelection.self, from: selectionData)
        else { throw StartError.malformedSelection }
        guard selection.kind != .application else {
            throw StartError.unsupportedSelection("\(selection.kind)")
        }

        let fps = qualityEnv[QualitySettings.fpsCapEnvKey].flatMap(Int.init) ?? 30
        let wantHEVC =
            !forceH264 && qualityEnv[QualitySettings.codecPrefEnvKey] == VideoCodec.hevc.rawValue

        let openedSession: WGC.Session
        do {
            openedSession = try WGC.Session(item: item)
        } catch {
            throw StartError.captureUnavailable("\(error)")
        }

        // Even dimensions: 4:2:0 chroma is half-resolution in both axes, and
        // libavcodec rounds the context down while `encode` still validates
        // plane sizes against what was asked for. Rounding here keeps the
        // conversion, the encoder and the guard talking about one geometry.
        let width = openedSession.width & ~1
        let height = openedSession.height & ~1
        guard width > 0, height > 0 else {
            throw StartError.captureUnavailable(
                "capture target reported \(openedSession.width)x\(openedSession.height)")
        }

        // Anchor the bitrate through the shared formula, so a share of the
        // same pixels starts at the same budget on every platform and the
        // congestion controller inherits a comparable baseline.
        let codec: VideoCodec = wantHEVC ? .hevc : .h264
        let formulaBitrate = EncoderTuning.computeBitrate(
            width: width, height: height, fps: fps,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: codec))
        let ceiling = qualityEnv[QualitySettings.maxBitrateEnvKey].flatMap(Int.init)
        let bitrate = min(formulaBitrate, ceiling ?? formulaBitrate)

        // Presence and usability are different questions — an encoder can be
        // compiled in and still refuse to open — so the ladder is driven by
        // `avcodec_open2` failing, the same shape as the mac encoder's
        // `sessionAttempts` fallback.
        let names = wantHEVC ? Self.defaultHEVCEncoders : Self.defaultH264Encoders
        var opened: FFmpeg.VideoEncoder?
        var attempts: [String] = []
        for name in names where FFmpeg.isEncoderAvailable(name) {
            do {
                opened = try FFmpeg.VideoEncoder(
                    codec: wantHEVC ? .hevc : .h264, width: width, height: height,
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
            throw StartError.encoderUnavailable(detail)
        }

        lock.lock()
        session = openedSession
        encoder = opened
        targetFPS = fps
        sentParameterSets = false
        // A viewer that connects before the GOP backstop fires has nothing to
        // decode, so the first frame out is always an IDR.
        keyframePending = true
        running = true
        lock.unlock()

        onEncoderResolution?(width, height)

        let captureThread = Thread { [weak self] in self?.captureLoop(width: width, height: height) }
        captureThread.name = "WGCCaptureEncoder"
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
        // Let the loop observe the flag and exit. It holds no lock while
        // waiting on a frame, and that wait is bounded by the acquire
        // timeout, so one interval plus slack is enough.
        try? await Task.sleep(for: .milliseconds(300))
        lock.withLock {
            session = nil
            encoder = nil
            thread = nil
        }
    }

    // MARK: Congestion levers

    public func requestKeyframe() {
        lock.withLock { keyframePending = true }
    }

    public func setBitrate(_ bps: Int) {
        let encoder = lock.withLock { self.encoder }
        encoder?.setBitrate(bps)
    }

    /// No system-audio capture here, so the emission latch has nothing to
    /// gate. An explicit no-op rather than an omission, so the server's
    /// re-send after every backend restart is harmless.
    public func setAudioEnabled(_ on: Bool) {}

    /// Retune the capture rate. Only the *pacing* changes: the encoder keeps
    /// its original time base, which is fine because RTP timestamps come from
    /// the server's clock rather than encoder PTS, and recreating the encoder
    /// to match would drop the stream mid-share for no benefit.
    public func setFrameInterval(_ fps: Int) {
        guard fps > 0 else { return }
        lock.withLock { targetFPS = fps }
    }

    // MARK: Capture loop

    private func captureLoop(width: Int, height: Int) {
        var timings = CaptureTimingAccumulator()
        let sizes = BGRAToI420.planeSizes(width: width, height: height)
        var yPlane = [UInt8](repeating: 0, count: sizes.y)
        var uPlane = [UInt8](repeating: 0, count: sizes.chroma)
        var vPlane = [UInt8](repeating: 0, count: sizes.chroma)
        /// Whether the planes hold a real captured frame yet. Until they do,
        /// a keyframe request has nothing to encode — see below.
        var havePlanes = false
        var consecutiveFailures = 0

        while true {
            let (stillRunning, fps) = lock.withLock { (running, targetFPS) }
            guard stillRunning else { break }
            let session = lock.withLock { self.session }
            let encoder = lock.withLock { self.encoder }
            guard let session, let encoder else { break }

            let frameStart = DispatchTime.now().uptimeNanoseconds
            var converted = false
            var convertNs: UInt64 = 0
            var encodeNs: UInt64 = 0
            do {
                // Nil means the acquire timed out, which for WGC is the
                // ORDINARY state of a still target: it produces a frame only
                // when the content changes. Not an error, and not a reason to
                // count a failure.
                let ok = try session.withFrame(timeoutMilliseconds: max(1, 1000 / max(1, fps))) {
                    frame -> Bool in
                    let convertStart = DispatchTime.now().uptimeNanoseconds
                    defer { convertNs = DispatchTime.now().uptimeNanoseconds &- convertStart }
                    return yPlane.withUnsafeMutableBufferPointer { y in
                        uPlane.withUnsafeMutableBufferPointer { u in
                            vPlane.withUnsafeMutableBufferPointer { v in
                                guard let yBase = y.baseAddress, let uBase = u.baseAddress,
                                    let vBase = v.baseAddress
                                else { return false }
                                return BGRAToI420.convert(
                                    BGRAToI420.Source(
                                        bgra: frame.bgra, stride: frame.stride,
                                        width: width, height: height),
                                    into: BGRAToI420.Planes(y: yBase, u: uBase, v: vBase))
                            }
                        }
                    }
                }
                converted = ok ?? false
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                // A window that closed or a display that was unplugged never
                // comes back, so spinning on it forever is worse than tearing
                // the share down. The server routes `source-gone` to a gentle
                // notice rather than an error alert.
                if consecutiveFailures >= 30 {
                    lock.withLock { running = false }
                    onUnexpectedExit?(
                        "source-gone: capture failed \(consecutiveFailures)x: \(error)")
                    return
                }
            }

            if converted { havePlanes = true }

            // Proof of life for the server's hung-backend watchdog, fired
            // every iteration because this backend has no separate heartbeat
            // — and deliberately fired on a timeout too, since a static screen
            // is healthy rather than wedged. Exactly the reason the macOS
            // helper emits a heartbeat off `.idle` samples.
            onActivity?()

            // Encode when there is something new, OR when a keyframe is owed
            // and there is a previous frame to make one from.
            //
            // That second case is not an optimisation. Unlike SCStream and
            // unlike X11 grabbing, WGC delivers nothing at all while the
            // target is still — so a viewer that joins, or PLIs, during a
            // motionless moment would wait for the user to jiggle something
            // before it could decode anything. Re-encoding the retained
            // planes answers immediately with the picture that is actually on
            // screen.
            let owedKeyframe = lock.withLock {
                let owed = keyframePending
                keyframePending = false
                return owed
            }
            if converted || (owedKeyframe && havePlanes) {
                if owedKeyframe { encoder.requestKeyframe() }
                let encodeStart = DispatchTime.now().uptimeNanoseconds
                do {
                    for accessUnit in try encoder.encode(
                        yPlane: yPlane, uPlane: uPlane, vPlane: vPlane)
                    {
                        if accessUnit.isKeyframe { emitParameterSets(from: accessUnit.data) }
                        onAccessUnit?(accessUnit.data, accessUnit.isKeyframe)
                    }
                    encodeNs = DispatchTime.now().uptimeNanoseconds &- encodeStart
                } catch {
                    // Put the request back: an encode that failed did not
                    // produce the keyframe someone is waiting for.
                    if owedKeyframe { lock.withLock { keyframePending = true } }
                }
            } else if owedKeyframe {
                // Nothing captured yet. Keep owing it rather than dropping it
                // on the floor.
                lock.withLock { keyframePending = true }
            }

            // `acquire` is the whole pass minus the two stages we timed —
            // i.e. waiting for the platform to hand over a frame, which is
            // the dominant cost when the screen is still and near zero when
            // it isn't. Measured by subtraction so the three numbers always
            // add up to the work actually done.
            let workNs = DispatchTime.now().uptimeNanoseconds &- frameStart
            let now = DispatchTime.now().uptimeNanoseconds
            timings.record(
                nowNs: now,
                acquireNs: workNs &- min(workNs, convertNs &+ encodeNs),
                convertNs: convertNs, encodeNs: encodeNs, producedFrame: converted)
            if let snapshot = timings.snapshot(nowNs: now) { onTimings?(snapshot) }

            let elapsed = workNs
            let interval = UInt64(1_000_000_000 / max(1, fps))
            if elapsed < interval {
                Thread.sleep(forTimeInterval: Double(interval - elapsed) / 1_000_000_000)
            }
        }
    }

    /// Hand the codec parameter sets up once per encoder configuration.
    ///
    /// They stay in-band on every keyframe regardless — that is what lets a
    /// viewer join mid-stream. This callback exists because the server caches
    /// the codec from it, and because the ordering contract
    /// (`onParameterSets` before `onEncoderResolution`) drives its
    /// adaptive-bitrate anchor.
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
