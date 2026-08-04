import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import X11CaptureKit

/// A Linux `CaptureEncoding` backend: X11 root-window capture into a
/// libavcodec encoder, producing the AVCC access units the sharer fans out.
///
/// This is the Linux counterpart of macOS's `HelperScreenCapture`. Everything
/// above it — viewer admission, RTP fan-out, NACK/FEC, congestion control —
/// is the portable `TailscaleScreenShareServer`, unchanged; this supplies only
/// pixels and honours the three congestion levers.
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
public final class X11CaptureEncoder: CaptureEncoding, @unchecked Sendable {
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
    /// Not part of `CaptureEncoding`: the seam's `onPreviewImage` hands over
    /// *encoded* bytes because the mac helper is a separate process and has
    /// ImageIO to encode with. This backend is in-process and has neither, so
    /// it hands raw pixels to the host, which owns the toolkit that can draw
    /// them. Attached in the host's capture factory, like `onTimings` on
    /// Windows — which also means a restart's fresh backend keeps publishing.
    ///
    /// Fires on the capture thread.
    public var onPreviewThumbnail: ((ThumbnailScaler.Thumbnail) -> Void)?

    public enum StartError: Error, CustomStringConvertible {
        case unsupportedSelection(String)
        case malformedSelection
        case captureUnavailable(String)
        case encoderUnavailable(String)

        public var description: String {
            switch self {
            case .unsupportedSelection(let k):
                return "this backend captures a whole X display; \(k) shares need the ScreenCast portal"
            case .malformedSelection: return "could not decode the picker selection"
            case .captureUnavailable(let m): return "X11 capture unavailable: \(m)"
            case .encoderUnavailable(let m): return "no usable video encoder: \(m)"
            }
        }
    }

    /// Encoders tried in order until one opens successfully.
    ///
    /// **Software only, deliberately.** `h264_vaapi` / `h264_nvenc` are
    /// present in most distro libavcodec builds — `avcodec_find_encoder_by_name`
    /// finds them — but they consume *hardware* frames: using one means
    /// creating an `AVHWFramesContext` and uploading each captured frame to
    /// GPU memory, which this backend's software-plane path doesn't do. Listing
    /// them here would pick an encoder that then fails at `avcodec_open2` on
    /// any machine without the matching device. Hardware encode is worth having
    /// (it's most of the CPU cost of a share) but it's a separate piece of
    /// work, not a name in a list.
    public static let defaultH264Encoders = ["libx264", "libopenh264"]
    public static let defaultHEVCEncoders = ["libx265"]

    private let lock = NSLock()
    private var capture: X11ScreenCapture?
    private var encoder: FFmpeg.VideoEncoder?
    private var thread: Thread?
    private var running = false
    /// Target capture rate. Retuned live by `setFrameInterval` — the fps
    /// ladder's second congestion lever.
    private var targetFPS = 30
    private var sentParameterSets = false
    private let display: String?

    /// - Parameter display: X display to capture, or nil for `$DISPLAY`.
    public init(display: String? = nil) {
        self.display = display
    }

    deinit {
        // Synchronous teardown only — no Task capturing self after deinit has
        // begun (the same rule the mac side follows).
        lock.lock()
        running = false
        lock.unlock()
    }

    // MARK: Lifecycle

    public func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws {
        guard let selection = try? JSONDecoder().decode(PickerSelection.self, from: selectionData) else {
            throw StartError.malformedSelection
        }
        guard selection.kind == .display else {
            throw StartError.unsupportedSelection("\(selection.kind)")
        }

        let fps = qualityEnv[QualitySettings.fpsCapEnvKey].flatMap(Int.init) ?? 30
        let wantHEVC =
            !forceH264 && qualityEnv[QualitySettings.codecPrefEnvKey] == VideoCodec.hevc.rawValue

        let cap: X11ScreenCapture
        do {
            cap = try X11ScreenCapture(display: display)
        } catch {
            throw StartError.captureUnavailable("\(error)")
        }

        // Anchor the bitrate the same way the mac helper does — the shared
        // formula in EncoderTuning — so both platforms start a share at the
        // same budget for the same pixels, and the congestion controller
        // inherits a comparable baseline.
        let codec: VideoCodec = wantHEVC ? .hevc : .h264
        let formulaBitrate = EncoderTuning.computeBitrate(
            width: cap.captureWidth, height: cap.captureHeight, fps: fps,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: codec))
        let ceiling = qualityEnv[QualitySettings.maxBitrateEnvKey].flatMap(Int.init)
        let bitrate = min(formulaBitrate, ceiling ?? formulaBitrate)

        // Try each candidate until one actually opens. Presence and usability
        // are different questions — an encoder can be compiled in and still
        // refuse to open — so the ladder is driven by `avcodec_open2` failing,
        // the same shape as the mac encoder's `sessionAttempts` fallback.
        let names = wantHEVC ? Self.defaultHEVCEncoders : Self.defaultH264Encoders
        var enc: FFmpeg.VideoEncoder?
        var attempts: [String] = []
        for name in names where FFmpeg.isEncoderAvailable(name) {
            do {
                enc = try FFmpeg.VideoEncoder(
                    codec: wantHEVC ? .hevc : .h264,
                    width: cap.captureWidth, height: cap.captureHeight,
                    fps: fps, bitrate: bitrate, encoderName: name)
                break
            } catch {
                attempts.append("\(name): \(error)")
            }
        }
        guard let enc else {
            let detail =
                attempts.isEmpty
                ? "none of \(names) present in this libavcodec build" : attempts.joined(separator: "; ")
            throw StartError.encoderUnavailable(detail)
        }

        lock.lock()
        capture = cap
        encoder = enc
        targetFPS = fps
        sentParameterSets = false
        running = true
        lock.unlock()

        onEncoderResolution?(enc.width, enc.height)

        let t = Thread { [weak self] in self?.captureLoop() }
        t.name = "X11CaptureEncoder"
        t.start()
        lock.lock()
        thread = t
        lock.unlock()
    }

    public func stop() async {
        // `withLock` rather than lock()/unlock(): the bare calls are
        // unavailable from an async context (nothing stops the task suspending
        // while holding it and resuming on another thread).
        let wasRunning = lock.withLock {
            let was = running
            running = false
            return was
        }
        guard wasRunning else { return }
        // Let the loop observe the flag and exit; it holds no lock while
        // sleeping, so one frame interval plus slack is enough.
        try? await Task.sleep(for: .milliseconds(200))
        lock.withLock {
            capture = nil
            encoder = nil
            thread = nil
        }
    }

    // MARK: Congestion levers

    public func requestKeyframe() {
        lock.lock()
        let e = encoder
        lock.unlock()
        e?.requestKeyframe()
    }

    public func setBitrate(_ bps: Int) {
        lock.lock()
        let e = encoder
        lock.unlock()
        e?.setBitrate(bps)
    }

    /// No system-audio capture in this backend, so the emission latch has
    /// nothing to gate. Implemented as an explicit no-op rather than omitted,
    /// so the server's post-restart re-send is harmless.
    public func setAudioEnabled(_ on: Bool) {}

    /// Retune the capture rate. Only the *pacing* changes — the encoder keeps
    /// its original time base, which is fine because RTP timestamps come from
    /// the server's own clock, not from encoder PTS. Recreating the encoder to
    /// match would drop the stream mid-share for no benefit.
    public func setFrameInterval(_ fps: Int) {
        guard fps > 0 else { return }
        lock.lock()
        targetFPS = fps
        lock.unlock()
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

        var consecutiveFailures = 0
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
                consecutiveFailures = 0
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
                consecutiveFailures += 1
                // A transient grab failure (the screen resized under us) is
                // worth retrying; a persistent one means the display is gone
                // and the share should tear down rather than spin.
                if consecutiveFailures >= 30 {
                    lock.lock()
                    running = false
                    lock.unlock()
                    onUnexpectedExit?("source-gone: X11 capture failed \(consecutiveFailures)x: \(error)")
                    return
                }
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds &- frameStart
            let interval = UInt64(1_000_000_000 / max(1, fps))
            if elapsed < interval {
                Thread.sleep(forTimeInterval: Double(interval - elapsed) / 1_000_000_000)
            }
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

    /// Pull SPS/PPS (or VPS/SPS/PPS) out of a keyframe access unit and hand
    /// them up once per encoder configuration.
    ///
    /// The parameter sets stay in-band on every keyframe regardless — that's
    /// what lets a viewer join mid-stream. This callback exists because the
    /// server caches the codec from it, and because the *ordering* contract
    /// (`onParameterSets` before `onEncoderResolution`) drives its
    /// adaptive-bitrate anchor.
    private func emitParameterSets(from avcc: Data) {
        lock.lock()
        let already = sentParameterSets
        let isHEVC = encoder?.codec == .hevc
        lock.unlock()
        guard !already, let handler = onParameterSets else { return }
        guard let annexB = NALUnit.avccToAnnexB(avcc) else { return }

        // The NAL-type masks differ between the codecs and getting them
        // crossed fails silently — viewers install nothing and sit on black
        // while this side looks perfect — so the table lives in
        // `ParameterSetExtraction`, shared with the Windows backend and
        // tested on Linux CI. Splitting Annex-B stays here: that half is
        // FFmpeg's, which the portable tier cannot name.
        guard
            let sets = ParameterSetExtraction.parameterSets(
                fromAnnexBNALs: NALUnit.annexBNALs(annexB),
                codec: isHEVC ? .hevc : .h264)
        else { return }
        lock.lock()
        sentParameterSets = true
        lock.unlock()
        handler(sets)
    }
}
