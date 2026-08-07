import FFmpegKit
import Foundation
import TailscreenProtocol

/// The shared scaffolding of the three FFmpeg-based `CaptureEncoding`
/// backends — Linux X11 (`X11CaptureEncoder`), Windows WGC
/// (`WGCCaptureEncoder`) and the ScreenCast portal (`PortalCaptureEncoder`).
///
/// Each of those backends owns a genuinely different capture loop (XSHM
/// grabbing with damage-free pacing, WGC's frame-pool acquire with the
/// still-target keyframe re-encode, PipeWire's push model through
/// `FrameHandoff`), and none of that lives here. What was identical in all
/// three — the seam's callback storage, the start-time quality decode, the
/// bitrate anchor, the encoder-attempt ladder, the stop sequence, the
/// congestion levers, the pacing tail, the parameter-set emission and the
/// consecutive-failure budget — was ~130 lines of scaffolding copied three
/// times, and lives here once.
///
/// **This class does not conform to `CaptureEncoding` itself** — it supplies
/// every member of that seam except `start`, and each backend declares the
/// conformance (satisfied by these inherited members plus its own `start`).
/// That keeps this module's dependencies to FFmpegKit + `TailscreenProtocol`
/// only: no `TailscreenSharer`, so its test bundle links no `libtailscale.a`,
/// and consuming it costs a backend nothing it did not already link.
///
/// **Subclassing notes.** Swift has no `protected`, and the subclasses live
/// in other modules, so the shared mutable state below is `public`. It is SPI
/// for conforming backends, not API for hosts: everything is guarded by
/// `lock`, and a subclass's capture loop reads `running`/`targetFPS` under it
/// exactly as the three existing loops do.
open class FFmpegCaptureEncoderBase: @unchecked Sendable {
    // MARK: CaptureEncoding callbacks

    public var onAccessUnit: ((Data, Bool) -> Void)?
    public var onAudioAccessUnit: ((Data) -> Void)?
    public var onParameterSets: ((CodecParameterSets) -> Void)?
    public var onEncoderResolution: ((Int, Int) -> Void)?
    public var onPreviewImage: ((Data) -> Void)?
    public var onUnexpectedExit: ((String) -> Void)?
    public var onUserStopped: (() -> Void)?
    public var onActivity: (() -> Void)?

    // MARK: Errors

    /// The one start-error shape all three backends throw.
    ///
    /// `unsupportedSelection` and `captureUnavailable` carry the **complete
    /// message** — each backend words its own refusal ("this backend captures
    /// a whole X display; …" vs "a capture item is one display or one
    /// window; …") — while the two texts that were identical everywhere live
    /// in `description` here so they cannot drift apart again.
    public enum StartError: Error, CustomStringConvertible {
        /// The picker selection decoded but this backend cannot serve its
        /// kind. The payload is the full sentence, worded by the backend.
        case unsupportedSelection(String)
        case malformedSelection
        /// The platform capture source would not open. The payload is the
        /// full sentence, worded by the backend.
        case captureUnavailable(String)
        /// No encoder in the ladder opened; the payload is the detail from
        /// ``encoderUnavailableDetail(names:attempts:)``.
        case encoderUnavailable(String)

        public var description: String {
            switch self {
            case .unsupportedSelection(let message): return message
            case .malformedSelection: return "could not decode the picker selection"
            case .captureUnavailable(let message): return message
            case .encoderUnavailable(let message): return "no usable video encoder: \(message)"
            }
        }
    }

    // MARK: Encoder ladder

    /// Encoders tried in order until one opens.
    ///
    /// **Software only, deliberately.** The hardware encoders most distro
    /// libavcodec builds carry — `h264_vaapi`/`h264_nvenc` on Linux,
    /// `h264_qsv`/`h264_nvenc`/`h264_amf` on Windows — are found by
    /// `avcodec_find_encoder_by_name` but consume *hardware* frames: using
    /// one means creating an `AVHWFramesContext` and uploading each captured
    /// frame to GPU memory, which the backends' software-plane paths don't
    /// do. Listing one here would pick an encoder that then fails at
    /// `avcodec_open2` on any machine without the matching device. Hardware
    /// encode is worth having (it's most of the CPU cost of a share) but it's
    /// a separate piece of work, not a name in a list.
    public static let defaultH264Encoders = ["libx264", "libopenh264"]
    public static let defaultHEVCEncoders = ["libx265"]

    /// The quality knobs every backend decodes from `start`'s
    /// `forceH264`/`qualityEnv` pair, in one place so the defaults cannot
    /// drift between platforms.
    public struct EncodeSettings: Sendable, Equatable {
        /// Target capture rate; `QualitySettings.fpsCapEnvKey`, default 30.
        public let fps: Int
        /// Whether the session should encode HEVC: the codec preference asked
        /// for it AND the `forceH264` fallback latch is off.
        public let wantHEVC: Bool
        /// `QualitySettings.maxBitrateEnvKey`, or nil for no ceiling.
        public let bitrateCeiling: Int?

        public init(forceH264: Bool, qualityEnv: [String: String]) {
            fps = qualityEnv[QualitySettings.fpsCapEnvKey].flatMap(Int.init) ?? 30
            wantHEVC =
                !forceH264 && qualityEnv[QualitySettings.codecPrefEnvKey] == VideoCodec.hevc.rawValue
            bitrateCeiling = qualityEnv[QualitySettings.maxBitrateEnvKey].flatMap(Int.init)
        }
    }

    /// Anchor the starting bitrate the same way the mac helper does — the
    /// shared formula in `EncoderTuning`, clamped to any ceiling — so a share
    /// of the same pixels starts at the same budget on every platform and the
    /// congestion controller inherits a comparable baseline.
    public static func anchoredBitrate(
        width: Int, height: Int, fps: Int, wantHEVC: Bool, ceiling: Int?
    ) -> Int {
        let codec: VideoCodec = wantHEVC ? .hevc : .h264
        let formulaBitrate = EncoderTuning.computeBitrate(
            width: width, height: height, fps: fps,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: codec))
        return min(formulaBitrate, ceiling ?? formulaBitrate)
    }

    /// The attempt ladder, generic over how an encoder opens so the ordering
    /// is testable without libavcodec having any encoder installed.
    ///
    /// Presence and usability are different questions — an encoder can be
    /// compiled in and still refuse to open — so the ladder is driven by
    /// `open` failing (`avcodec_open2` in production), the same shape as the
    /// mac encoder's `sessionAttempts` fallback. Names failing `isAvailable`
    /// are skipped without an attempt entry, exactly as the original
    /// `where FFmpeg.isEncoderAvailable(name)` loops did.
    public static func firstOpenableEncoder<Encoder>(
        names: [String],
        isAvailable: (String) -> Bool,
        open: (String) throws -> Encoder
    ) -> (encoder: Encoder?, attempts: [String]) {
        var attempts: [String] = []
        for name in names where isAvailable(name) {
            do {
                return (try open(name), attempts)
            } catch {
                attempts.append("\(name): \(error)")
            }
        }
        return (nil, attempts)
    }

    /// The detail string ``StartError/encoderUnavailable(_:)`` carries when
    /// the whole ladder fails.
    public static func encoderUnavailableDetail(names: [String], attempts: [String]) -> String {
        attempts.isEmpty
            ? "none of \(names) present in this libavcodec build"
            : attempts.joined(separator: "; ")
    }

    /// Run the ladder against the real libavcodec.
    public static func openSoftwareEncoder(
        wantHEVC: Bool, width: Int, height: Int, fps: Int, bitrate: Int
    ) throws -> FFmpeg.VideoEncoder {
        let names = wantHEVC ? defaultHEVCEncoders : defaultH264Encoders
        let (opened, attempts) = firstOpenableEncoder(
            names: names,
            isAvailable: FFmpeg.isEncoderAvailable
        ) { name in
            try FFmpeg.VideoEncoder(
                codec: wantHEVC ? .hevc : .h264, width: width, height: height,
                fps: fps, bitrate: bitrate, encoderName: name)
        }
        guard let opened else {
            throw StartError.encoderUnavailable(
                encoderUnavailableDetail(names: names, attempts: attempts))
        }
        return opened
    }

    // MARK: Failure budget

    /// The consecutive-capture-failure budget: a transient grab failure (the
    /// screen resized under us) is worth retrying; a persistent one means the
    /// source is gone and the share should tear down rather than spin. The
    /// `source-gone:` prefix routes the exit to the server's gentle
    /// shared-window-closed handling instead of an error alert.
    public struct SourceGoneBudget: Sendable {
        public static let defaultLimit = 30

        public private(set) var consecutiveFailures = 0
        public let limit: Int

        public init(limit: Int = SourceGoneBudget.defaultLimit) {
            self.limit = limit
        }

        public mutating func noteSuccess() {
            consecutiveFailures = 0
        }

        /// Count a failure. Returns the `onUnexpectedExit` reason once the
        /// budget is exhausted, nil while retrying is still worthwhile.
        /// `subject` names the failing stage in the message ("X11 capture"
        /// on Linux, "capture" on Windows — the strings each backend always
        /// emitted).
        public mutating func noteFailure(subject: String, error: any Error) -> String? {
            consecutiveFailures += 1
            guard consecutiveFailures >= limit else { return nil }
            return "source-gone: \(subject) failed \(consecutiveFailures)x: \(error)"
        }
    }

    // MARK: Pacing

    /// How long the capture loop should sleep to hold `fps`, given the work
    /// already done this pass — or nil when the pass already overran the
    /// frame interval.
    public static func frameSleepSeconds(elapsedNs: UInt64, fps: Int) -> Double? {
        let interval = UInt64(1_000_000_000 / max(1, fps))
        guard elapsedNs < interval else { return nil }
        return Double(interval - elapsedNs) / 1_000_000_000
    }

    /// The pacing tail every capture loop ends with.
    public static func paceFrame(elapsedNs: UInt64, fps: Int) {
        if let seconds = frameSleepSeconds(elapsedNs: elapsedNs, fps: fps) {
            Thread.sleep(forTimeInterval: seconds)
        }
    }

    // MARK: Shared state

    /// Guards every mutable field below, in this class and in the subclass —
    /// one lock, so a backend's own state (its capture handle, its rebuild
    /// request) and the shared state can be read together consistently.
    public let lock = NSLock()
    public var encoder: FFmpeg.VideoEncoder?
    public var thread: Thread?
    public var running = false
    /// Target capture rate. Retuned live by `setFrameInterval` — the fps
    /// ladder's second congestion lever.
    public var targetFPS = 30
    public var sentParameterSets = false
    /// Set by `requestKeyframe` (in the two backends that keep the default)
    /// and consumed by their capture loops via ``takeOwedKeyframe()`` —
    /// needed where a keyframe may have to be produced when no NEW frame is
    /// arriving. The X11 backend forwards straight to the encoder instead
    /// and never reads this.
    public var keyframePending = false

    public init() {}

    deinit {
        // Synchronous teardown only — no Task capturing self after deinit has
        // begun (the same rule the mac side follows).
        lock.lock()
        running = false
        lock.unlock()
    }

    // MARK: Lifecycle

    /// Spawn the capture loop's thread and record it. The body should be
    /// `{ [weak self] in self?.captureLoop() }` — weak, because the thread
    /// must not keep a stopped backend alive.
    public func startCaptureThread(named name: String, _ body: @escaping @Sendable () -> Void) {
        let captureThread = Thread { body() }
        captureThread.name = name
        captureThread.start()
        lock.withLock { thread = captureThread }
    }

    /// How long `stop()` waits for the capture loop to observe the dropped
    /// flag before releasing resources. The loop holds no lock while it
    /// sleeps or waits on a frame, so one frame interval plus slack is
    /// enough; a backend whose wait is bounded differently overrides this.
    open var stopSettleMilliseconds: Int { 300 }

    /// Called by `stop()` right after the running flag drops and before the
    /// settle sleep. The portal backend releases its stream here (its deinit
    /// stops PipeWire's thread, guaranteeing no frame callback is in flight
    /// by the time the buffers go away).
    open func willStopBeforeSettle() {}

    /// Called by `stop()` under `lock` after the settle sleep, for the
    /// subclass to nil out its own capture resources (the X11 capture, the
    /// WGC session, the portal's hand-off buffers).
    open func releaseCaptureResourcesLocked() {}

    public func stop() async {
        // `withLock` rather than lock()/unlock(): the bare calls are
        // unavailable from an async context (nothing stops the task
        // suspending while holding it and resuming on another thread).
        let wasRunning = lock.withLock {
            let was = running
            running = false
            return was
        }
        guard wasRunning else { return }
        willStopBeforeSettle()
        // Let the loop observe the flag and exit.
        try? await Task.sleep(for: .milliseconds(stopSettleMilliseconds))
        lock.withLock {
            encoder = nil
            thread = nil
            releaseCaptureResourcesLocked()
        }
    }

    // MARK: Congestion levers

    /// Force an IDR on the next frame. The default latches
    /// ``keyframePending`` for the capture loop to consume — the right shape
    /// for backends that may have to re-encode a retained frame — and the
    /// X11 backend overrides it to forward straight to the encoder.
    open func requestKeyframe() {
        lock.withLock { keyframePending = true }
    }

    /// Consume a pending keyframe request, if any.
    public func takeOwedKeyframe() -> Bool {
        lock.withLock {
            let owed = keyframePending
            keyframePending = false
            return owed
        }
    }

    open func setBitrate(_ bps: Int) {
        let encoder = lock.withLock { self.encoder }
        encoder?.setBitrate(bps)
    }

    /// None of the three backends captures system audio, so the emission
    /// latch has nothing to gate. An explicit no-op rather than an omission,
    /// so the server's re-send after every backend restart is harmless.
    public func setAudioEnabled(_ on: Bool) {}

    /// Retune the capture rate. Only the *pacing* changes — the encoder
    /// keeps its original time base, which is fine because RTP timestamps
    /// come from the server's own clock, not from encoder PTS. Recreating
    /// the encoder to match would drop the stream mid-share for no benefit.
    public func setFrameInterval(_ fps: Int) {
        guard fps > 0 else { return }
        lock.withLock { targetFPS = fps }
    }

    // MARK: Parameter sets

    /// Pull SPS/PPS (or VPS/SPS/PPS) out of a keyframe access unit and hand
    /// them up once per encoder configuration.
    ///
    /// The parameter sets stay in-band on every keyframe regardless — that's
    /// what lets a viewer join mid-stream. This callback exists because the
    /// server caches the codec from it, and because the *ordering* contract
    /// (`onParameterSets` before `onEncoderResolution`) drives its
    /// adaptive-bitrate anchor.
    ///
    /// The NAL-type masks differ between the codecs and getting them crossed
    /// fails silently — viewers install nothing and sit on black while this
    /// side looks perfect — so the table lives in `ParameterSetExtraction`,
    /// tested on Linux CI. Splitting Annex-B stays FFmpeg-side (`NALUnit`),
    /// which the portable tier cannot name.
    public func emitParameterSets(from avcc: Data) {
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
