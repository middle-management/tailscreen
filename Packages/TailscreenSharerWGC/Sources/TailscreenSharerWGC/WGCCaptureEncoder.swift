import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerFFmpegBase
import WGCCaptureKit

/// A Windows `CaptureEncoding` backend: Windows.Graphics.Capture into a
/// libavcodec encoder, producing the AVCC access units the sharer fans out.
///
/// The Windows counterpart of macOS's `HelperScreenCapture` and Linux's
/// `X11CaptureEncoder`, and structurally the latter — everything above it
/// (admission, RTP fan-out, NACK/FEC, congestion control) is the portable
/// `TailscaleScreenShareServer`, unchanged. This supplies pixels and honours
/// the three congestion levers; the scaffolding all three FFmpeg backends
/// share is `FFmpegCaptureEncoderBase`, and this file is the capture loop and
/// the WGC specifics.
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
/// - `onPreviewImage`, which carries *encoded* image bytes because the mac
///   helper is a separate process with ImageIO on the far side. Raw pixels
///   go up through `onPreviewThumbnail` instead.
/// - Cloaked Apps. Windows has no equivalent knob: `WDA_EXCLUDEFROMCAPTURE`
///   is set by a window's own owner, so a capturer cannot exclude someone
///   else's window under either capture API. `excludedBundleIDs` is ignored,
///   and the host must not offer the setting on this platform.
public final class WGCCaptureEncoder: FFmpegCaptureEncoderBase, CaptureEncoding, @unchecked Sendable {
    /// Per-stage timings, once a second. Not part of `CaptureEncoding` — it is
    /// this backend's own diagnostic, and the question it answers ("which of
    /// capture, convert and encode is the slow one") is one a viewer's stats
    /// overlay structurally cannot: from the far end a slow sharer and a quiet
    /// screen look identical.
    public var onTimings: ((CaptureTimings) -> Void)?

    /// The sharer's own "this is what they can see" thumbnail, at most once a
    /// second (`ThumbnailScaler.intervalNs`).
    ///
    /// Not part of `CaptureEncoding` either, and for the same reason as
    /// `onTimings`: attached in the host's capture factory, so a restart's
    /// fresh backend keeps publishing without the seam growing a member every
    /// host but one leaves nil.
    ///
    /// Fires on the capture thread.
    public var onPreviewThumbnail: ((ThumbnailScaler.Thumbnail) -> Void)?

    private let item: WGC.CaptureItem
    private var session: WGC.Session?

    /// - Parameter item: the target the user already chose, via
    ///   ``WGC/CaptureItem/pick(ownerWindow:)`` or one of the no-UI
    ///   constructors.
    public init(item: WGC.CaptureItem) {
        self.item = item
        super.init()
    }

    // MARK: Lifecycle

    public func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws {
        guard let selection = try? JSONDecoder().decode(PickerSelection.self, from: selectionData)
        else { throw StartError.malformedSelection }
        guard selection.kind != .application else {
            throw StartError.unsupportedSelection(
                "a capture item is one display or one window; \(selection.kind) shares are not supported here"
            )
        }

        let settings = EncodeSettings(forceH264: forceH264, qualityEnv: qualityEnv)

        let openedSession: WGC.Session
        do {
            openedSession = try WGC.Session(item: item)
        } catch {
            throw StartError.captureUnavailable("screen capture unavailable: \(error)")
        }

        // Even dimensions: 4:2:0 chroma is half-resolution in both axes, and
        // libavcodec rounds the context down while `encode` still validates
        // plane sizes against what was asked for. Rounding here keeps the
        // conversion, the encoder and the guard talking about one geometry.
        let width = openedSession.width & ~1
        let height = openedSession.height & ~1
        guard width > 0, height > 0 else {
            throw StartError.captureUnavailable(
                "screen capture unavailable: capture target reported \(openedSession.width)x\(openedSession.height)"
            )
        }

        let bitrate = Self.anchoredBitrate(
            width: width, height: height, fps: settings.fps,
            wantHEVC: settings.wantHEVC, ceiling: settings.bitrateCeiling)
        let opened = try Self.openSoftwareEncoder(
            wantHEVC: settings.wantHEVC, width: width, height: height,
            fps: settings.fps, bitrate: bitrate)

        lock.lock()
        session = openedSession
        encoder = opened
        targetFPS = settings.fps
        sentParameterSets = false
        // A viewer that connects before the GOP backstop fires has nothing to
        // decode, so the first frame out is always an IDR.
        keyframePending = true
        running = true
        lock.unlock()

        onEncoderResolution?(width, height)

        startCaptureThread(named: "WGCCaptureEncoder") { [weak self] in
            self?.captureLoop(width: width, height: height)
        }
    }

    /// The loop holds no lock while waiting on a frame, and that wait is
    /// bounded by the acquire timeout, so one interval plus slack is enough.
    override public var stopSettleMilliseconds: Int { 300 }

    override public func releaseCaptureResourcesLocked() {
        session = nil
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
        var budget = SourceGoneBudget()
        var lastPreviewNs: UInt64?

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
            // Decided before the frame is acquired so the sink is called
            // OUTSIDE `withFrame`, which holds the D3D surface mapped: whatever
            // the host does with a thumbnail (marshal to a UI thread, redraw a
            // card) must not run while a capture surface is locked.
            let previewSink =
                ThumbnailScaler.shouldCapture(lastCaptureNs: lastPreviewNs, nowNs: frameStart)
                ? onPreviewThumbnail : nil
            var thumbnail: ThumbnailScaler.Thumbnail?
            do {
                // Nil means the acquire timed out, which for WGC is the
                // ORDINARY state of a still target: it produces a frame only
                // when the content changes. Not an error, and not a reason to
                // count a failure.
                let ok = try session.withFrame(timeoutMilliseconds: max(1, 1000 / max(1, fps))) {
                    frame -> Bool in
                    let convertStart = DispatchTime.now().uptimeNanoseconds
                    let ok = yPlane.withUnsafeMutableBufferPointer { y in
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
                    // Stopped before the preview: the timing answers "is the
                    // colour conversion the slow stage", and folding a
                    // once-a-second thumbnail into it would put a spike in that
                    // number every second that no per-frame stage caused.
                    convertNs = DispatchTime.now().uptimeNanoseconds &- convertStart
                    // Scaled from the BGRA rather than back out of the planes:
                    // it is right here, mapped, and valid only for this call.
                    if previewSink != nil {
                        thumbnail = ThumbnailScaler.thumbnail(
                            bgra: frame.bgra, stride: frame.stride,
                            width: width, height: height)
                    }
                    return ok
                }
                converted = ok ?? false
                budget.noteSuccess()
            } catch {
                // A window that closed or a display that was unplugged never
                // comes back, so spinning on it forever is worse than tearing
                // the share down. The server routes `source-gone` to a gentle
                // notice rather than an error alert.
                if let reason = budget.noteFailure(subject: "capture", error: error) {
                    lock.withLock { running = false }
                    onUnexpectedExit?(reason)
                    return
                }
            }

            if converted { havePlanes = true }

            // Outside `withFrame`, so the host's redraw never runs with a
            // capture surface mapped. Only when a frame actually arrived: a
            // still target produces none, and moving the mark forward on a
            // timed-out acquire would silently skip the next real preview.
            if let previewSink, let thumbnail {
                lastPreviewNs = frameStart
                previewSink(thumbnail)
            }

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
            let owedKeyframe = takeOwedKeyframe()
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

            Self.paceFrame(elapsedNs: workNs, fps: fps)
        }
    }
}
