import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerFFmpegBase
import X11CaptureKit

/// A Linux `CaptureEncoding` backend: X11 root-window capture into a
/// libavcodec encoder, producing the AVCC access units the sharer fans out.
/// Linux counterpart of macOS's `HelperScreenCapture`; encode-send scaffolding
/// shared with the other FFmpeg backends is `FFmpegCaptureEncoderBase` — this
/// file is the capture loop and X11 specifics.
///
/// **Scope.** Root-window capture on X11 only:
/// - Per-window/app shares need the compositor (ScreenCast portal); `start`
///   rejects them rather than silently sharing the whole screen.
/// - No system-audio capture; viewer voice still works separately.
/// - `onPreviewImage` never fires (that seam carries encoded bytes, the mac
///   helper's shape) — publishes raw pixels through `onPreviewThumbnail` instead.
/// - Wayland is the portal backend's job.
///
/// **No helper subprocess** — unlike macOS, which isolates capture in a child
/// to release `replayd`'s slot on process death; Linux has no such coupling.
public final class X11CaptureEncoder: FFmpegCaptureEncoderBase, CaptureEncoding, @unchecked Sendable {
    // MARK: Preview

    /// The sharer's own "this is what they can see" thumbnail, at most once a
    /// second. Not part of `CaptureEncoding` (that seam's `onPreviewImage`
    /// carries encoded bytes for the mac helper); this in-process backend
    /// hands raw pixels instead. Fires on the capture thread.
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
    /// frame per pass, so a keyframe is never owed with nothing to encode it
    /// from (the case the base's pending latch exists for).
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
        // First frame must be a keyframe, or a viewer connecting before the
        // GOP backstop fires has nothing to decode.
        enc.requestKeyframe()

        var budget = SourceGoneBudget()
        // Allocated once, not per thumbnail: a full-frame BGRA buffer (33 MB
        // at 4K) churned through the allocator once a second is wasted cost.
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
                // Proof of life for the watchdog, fired per frame even when
                // the encoder emitted nothing — a static screen is healthy, not wedged.
                onActivity?()
                for au in aus {
                    if au.isKeyframe {
                        emitParameterSets(from: au.data)
                    }
                    onAccessUnit?(au.data, au.isKeyframe)
                }
                // Preview last: the encode is what viewers are waiting on.
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

    /// Turn the frame just captured into a preview thumbnail. Converts back
    /// I420→BGRA since `X11ScreenCapture.grab` does BGRA→I420 in its C shim
    /// and discards the original; the chroma-resolution cost is below what a
    /// 240px thumbnail could show anyway.
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
