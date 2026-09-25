import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerFFmpegBase
import WGCCaptureKit

/// A Windows `CaptureEncoding` backend: Windows.Graphics.Capture into a
/// libavcodec encoder, producing the AVCC access units the sharer fans out.
/// The Windows counterpart of macOS's `HelperScreenCapture` and Linux's
/// `X11CaptureEncoder`.
///
/// **Constructed with an already-picked target, not an ID** — a
/// `GraphicsCaptureItem` is an opaque WinRT object with no stable identifier
/// to serialize and resolve later. The host picks once, holds the item, and
/// the capture factory closes over it, so a restart re-targets the same
/// window without asking the user again.
///
/// **Scope.** Display and single-window shares (why WGC over DXGI Desktop
/// Duplication, which is whole-output-only). Not covered:
/// - Multi-window application shares — rejected rather than silently widened
///   to the display (a privacy failure, not a missing feature).
/// - System-audio capture; viewer voice is unaffected.
/// - `onPreviewImage` (encoded bytes for the mac helper's ImageIO) — raw
///   pixels go through `onPreviewThumbnail` instead.
/// - Cloaked Apps: Windows has no equivalent to `WDA_EXCLUDEFROMCAPTURE` for
///   a capturer to use; `excludedBundleIDs` is ignored here.
public final class WGCCaptureEncoder: FFmpegCaptureEncoderBase, CaptureEncoding, @unchecked Sendable {
    /// Per-stage timings, once a second — answers "which of capture, convert,
    /// encode is slow", which a viewer's stats overlay structurally can't
    /// (a slow sharer and a quiet screen look identical from the far end).
    public var onTimings: ((CaptureTimings) -> Void)?

    /// The sharer's own "this is what they can see" thumbnail, at most once
    /// a second. Fires on the capture thread.
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
        // rounding here keeps the conversion, encoder and guard aligned.
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
        keyframePending = true  // first frame out is always an IDR
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
            // Decided before acquire so the sink is called OUTSIDE `withFrame`,
            // which holds the D3D surface mapped.
            let previewSink =
                ThumbnailScaler.shouldCapture(lastCaptureNs: lastPreviewNs, nowNs: frameStart)
                ? onPreviewThumbnail : nil
            var thumbnail: ThumbnailScaler.Thumbnail?
            do {
                // Nil means the acquire timed out — the ordinary state of a
                // still target (WGC only produces a frame when content changes).
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
                    // Stopped before the preview: folding a once-a-second
                    // thumbnail into this timing would spike it every second.
                    convertNs = DispatchTime.now().uptimeNanoseconds &- convertStart
                    // Scaled from the BGRA (right here, mapped) rather than
                    // back out of the planes.
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
                // A window closed or display unplugged never comes back, so
                // spinning forever is worse than tearing down the share.
                if let reason = budget.noteFailure(subject: "capture", error: error) {
                    lock.withLock { running = false }
                    onUnexpectedExit?(reason)
                    return
                }
            }

            if converted { havePlanes = true }

            // Outside `withFrame`, so the host's redraw never runs with a
            // capture surface mapped. Only fires on a real frame — advancing
            // the mark on a timed-out acquire would skip the next real preview.
            if let previewSink, let thumbnail {
                lastPreviewNs = frameStart
                previewSink(thumbnail)
            }

            // Proof of life for the watchdog, fired every iteration
            // (including on timeout — a static screen is healthy, not wedged).
            onActivity?()

            // Encode when new, OR when a keyframe is owed and there's a
            // previous frame — WGC delivers nothing while the target is
            // still, so a joining viewer would otherwise wait for motion.
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
                    // Put the request back — the failed encode didn't produce it.
                    if owedKeyframe { lock.withLock { keyframePending = true } }
                }
            } else if owedKeyframe {
                lock.withLock { keyframePending = true }
            }

            // `acquire` is the whole pass minus the two timed stages, measured
            // by subtraction so the three numbers always add up.
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
