import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerFFmpegBase
import X11CaptureKit

/// A Linux `CaptureEncoding` backend: X11 root-window capture into a
/// libavcodec encoder, producing the AVCC access units the sharer fans out.
///
/// This is the Linux counterpart of macOS's `HelperScreenCapture`. Everything
/// above it — viewer admission, RTP fan-out, NACK/FEC, congestion control —
/// is the portable `TailscaleScreenShareServer`, unchanged; this supplies only
/// pixels and honours the three congestion levers. The encode-send
/// scaffolding all three FFmpeg backends share (callbacks, encoder ladder,
/// stop sequence, levers, pacing) is `FFmpegCaptureEncoderBase`; this file is
/// the capture loop and the X11 specifics.
///
/// **Scope, stated plainly.** Root-window capture on X11 only:
/// - Per-window and per-application shares are not implemented — those need
///   the compositor's cooperation, which is what the ScreenCast portal is for.
///   `start` rejects them rather than silently sharing the whole screen, which
///   would be a privacy failure, not a missing feature.
/// - No system-audio capture, so `setAudioEnabled` is a no-op and
///   `onAudioAccessUnit` never fires. Viewer voice still works — that path
///   doesn't come through here.
/// - `onPreviewImage` never fires — that seam carries *encoded* image data,
///   which is the mac helper's shape (it has ImageIO on the far side of an
///   IPC boundary). This host has neither, so it publishes raw pixels through
///   `onPreviewThumbnail` instead.
/// - Wayland is not covered. The portal backend is the answer there, behind
///   this same protocol.
///
/// **No helper subprocess.** macOS isolates capture in a child because
/// process death is the only way to release `replayd`'s slot. Linux has no
/// such coupling (plans/porting-plan.md #10), so capture runs in-process and
/// `stop()` genuinely stops it.
public final class X11CaptureEncoder: FFmpegCaptureEncoderBase, CaptureEncoding, @unchecked Sendable {
    // MARK: Preview

    /// The sharer's own "this is what they can see" thumbnail, at most once a
    /// second (`ThumbnailScaler.intervalNs`).
    ///
    /// Not part of `CaptureEncoding`: the seam's `onPreviewImage` hands over
    /// *encoded* bytes because the mac helper is a separate process and has
    /// ImageIO to encode with. This backend is in-process and has neither, so
    /// it hands raw pixels to the host, which owns the toolkit that can draw
    /// them. Attached in the host's capture factory, like `onTimings` on
    /// Windows — which also means a restart's fresh backend keeps publishing.
    ///
    /// Fires on the capture thread.
    public var onPreviewThumbnail: ((ThumbnailScaler.Thumbnail) -> Void)?

    private var capture: X11ScreenCapture?
    private let display: String?

    /// - Parameter display: X display to capture, or nil for `$DISPLAY`.
    public init(display: String? = nil) {
        self.display = display
        super.init()
    }

    // MARK: Lifecycle

    public func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws {
        guard let selection = try? JSONDecoder().decode(PickerSelection.self, from: selectionData) else {
            throw StartError.malformedSelection
        }
        guard selection.kind == .display else {
            throw StartError.unsupportedSelection(
                "this backend captures a whole X display; \(selection.kind) shares need the ScreenCast portal"
            )
        }

        let settings = EncodeSettings(forceH264: forceH264, qualityEnv: qualityEnv)

        let cap: X11ScreenCapture
        do {
            cap = try X11ScreenCapture(display: display)
        } catch {
            throw StartError.captureUnavailable("X11 capture unavailable: \(error)")
        }

        let bitrate = Self.anchoredBitrate(
            width: cap.captureWidth, height: cap.captureHeight, fps: settings.fps,
            wantHEVC: settings.wantHEVC, ceiling: settings.bitrateCeiling)
        let enc = try Self.openSoftwareEncoder(
            wantHEVC: settings.wantHEVC,
            width: cap.captureWidth, height: cap.captureHeight,
            fps: settings.fps, bitrate: bitrate)

        lock.lock()
        capture = cap
        encoder = enc
        targetFPS = settings.fps
        sentParameterSets = false
        running = true
        lock.unlock()

        onEncoderResolution?(enc.width, enc.height)

        startCaptureThread(named: "X11CaptureEncoder") { [weak self] in self?.captureLoop() }
    }

    /// The loop holds no lock while sleeping, so one frame interval plus
    /// slack is enough.
    override public var stopSettleMilliseconds: Int { 200 }

    override public func releaseCaptureResourcesLocked() {
        capture = nil
    }

    // MARK: Congestion levers

    /// Forwarded straight to the encoder: X11 grabbing always produces a
    /// frame per pass, so there is never a keyframe owed with nothing to
    /// encode it from (the case the base's pending latch exists for).
    override public func requestKeyframe() {
        lock.lock()
        let e = encoder
        lock.unlock()
        e?.requestKeyframe()
    }

    // MARK: Capture loop

    private func captureLoop() {
        lock.lock()
        guard let cap = capture, let enc = encoder else {
            lock.unlock()
            return
        }
        lock.unlock()

        var planes = cap.makePlanes()
        // First frame must be a keyframe: a viewer that connects before the
        // GOP backstop fires has nothing to decode otherwise.
        enc.requestKeyframe()

        var budget = SourceGoneBudget()
        // Preview scratch, allocated once rather than per thumbnail: this is a
        // full-frame BGRA buffer (33 MB at 4 K), and churning one of those
        // through the allocator once a second for the life of a share is a
        // cost with nothing to show for it.
        var previewScratch: [UInt8] = []
        var lastPreviewNs: UInt64?
        while true {
            lock.lock()
            let stillRunning = running
            let fps = targetFPS
            lock.unlock()
            guard stillRunning else { break }

            let frameStart = DispatchTime.now().uptimeNanoseconds
            do {
                try cap.grab(into: &planes)
                let aus = try enc.encode(yPlane: planes.y, uPlane: planes.u, vPlane: planes.v)
                budget.noteSuccess()
                // Proof of life for the server's hung-backend watchdog. Fired
                // per frame because this backend has no separate heartbeat —
                // and deliberately fired even when the encoder emitted nothing,
                // since a static screen is healthy, not wedged.
                onActivity?()
                for au in aus {
                    if au.isKeyframe {
                        emitParameterSets(from: au.data)
                    }
                    onAccessUnit?(au.data, au.isKeyframe)
                }
                // Preview last: the encode is what viewers are waiting on, and
                // this is a courtesy to the person already looking at their own
                // screen.
                if let sink = onPreviewThumbnail,
                    ThumbnailScaler.shouldCapture(lastCaptureNs: lastPreviewNs, nowNs: frameStart)
                {
                    lastPreviewNs = frameStart
                    publishPreview(planes: planes, scratch: &previewScratch, to: sink)
                }
            } catch {
                if let reason = budget.noteFailure(subject: "X11 capture", error: error) {
                    lock.lock()
                    running = false
                    lock.unlock()
                    onUnexpectedExit?(reason)
                    return
                }
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds &- frameStart
            Self.paceFrame(elapsedNs: elapsed, fps: fps)
        }
    }

    /// Turn the frame just captured into a preview thumbnail.
    ///
    /// **Yes, this converts back.** `X11ScreenCapture.grab` does BGRA→I420
    /// inside its C shim and hands out planes only, so the BGRA it read is gone
    /// by the time we get here and the only way back to pixels is I420→BGRA.
    /// That round trip costs chroma resolution — which at 240 px across is
    /// below anything a thumbnail could show — and the alternative is widening
    /// the capture shim's contract to keep a copy of a full-size frame nobody
    /// else wants, on every frame, so that one frame a second can be scaled.
    private func publishPreview(
        planes: X11ScreenCapture.Planes,
        scratch: inout [UInt8],
        to sink: (ThumbnailScaler.Thumbnail) -> Void
    ) {
        let width = planes.width
        let height = planes.height
        let needed = width * height * ThumbnailScaler.bytesPerPixel
        guard needed > 0 else { return }
        if scratch.count != needed { scratch = [UInt8](repeating: 0, count: needed) }

        var thumbnail: ThumbnailScaler.Thumbnail?
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                I420Converter.convert(
                    I420Converter.Source(
                        yPlane: planes.y, uPlane: planes.u, vPlane: planes.v,
                        width: width, height: height),
                    into: base)
            else { return }
            thumbnail = ThumbnailScaler.thumbnail(
                bgra: UnsafePointer(base),
                stride: width * ThumbnailScaler.bytesPerPixel,
                width: width, height: height)
        }
        guard let thumbnail else { return }
        sink(thumbnail)
    }
}
