import FFmpegKit
import Foundation
import TailscreenProtocol

/// The shared scaffolding of the three FFmpeg-based `CaptureEncoding`
/// backends — Linux X11 (`X11CaptureEncoder`), Windows WGC
/// (`WGCCaptureEncoder`) and the ScreenCast portal (`PortalCaptureEncoder`).
/// Each owns a genuinely different capture loop; what was identical (callback
/// storage, quality decode, bitrate anchor, encoder ladder, stop sequence,
/// congestion levers, pacing, parameter-set emission, failure budget) lives here once.
///
/// **Does not conform to `CaptureEncoding` itself** — supplies every member
/// except `start`; each backend declares the conformance. Keeps this
/// module's dependencies to FFmpegKit + `TailscreenProtocol` only, so its
/// test bundle links no `libtailscale.a`.
///
/// **Subclassing:** Swift has no `protected` and subclasses live in other
/// modules, so the shared mutable state below is `public` SPI, guarded by `lock`.
///
/// **Callback contract: set every callback before `start()`, never mutate
/// after.** The capture thread reads them on every frame; a reassignment can
/// land between the parameter-set emission and the access unit that needs
/// it, leaving a viewer on black. Every shipped host wires them inside the
/// capture factory, before `start` is called.
open class FFmpegCaptureEncoderBase: @unchecked Sendable {
    // MARK: CaptureEncoding callbacks
    //
    // Stored behind `lock`, not as bare vars: written by the host thread,
    // read by the capture thread every frame. None of the three subclasses
    // invokes one while holding `lock` — `NSLock` is not recursive.

    public var onAccessUnit: ((Data, Bool) -> Void)? {
        get { lock.withLock { accessUnitSink } }
        set { lock.withLock { accessUnitSink = newValue } }
    }
    public var onAudioAccessUnit: ((Data) -> Void)? {
        get { lock.withLock { audioAccessUnitSink } }
        set { lock.withLock { audioAccessUnitSink = newValue } }
    }
    public var onParameterSets: ((CodecParameterSets) -> Void)? {
        get { lock.withLock { parameterSetsSink } }
        set { lock.withLock { parameterSetsSink = newValue } }
    }
    public var onEncoderResolution: ((Int, Int) -> Void)? {
        get { lock.withLock { encoderResolutionSink } }
        set { lock.withLock { encoderResolutionSink = newValue } }
    }
    public var onPreviewImage: ((Data) -> Void)? {
        get { lock.withLock { previewImageSink } }
        set { lock.withLock { previewImageSink = newValue } }
    }
    public var onUnexpectedExit: ((String) -> Void)? {
        get { lock.withLock { unexpectedExitSink } }
        set { lock.withLock { unexpectedExitSink = newValue } }
    }
    public var onUserStopped: (() -> Void)? {
        get { lock.withLock { userStoppedSink } }
        set { lock.withLock { userStoppedSink = newValue } }
    }
    public var onActivity: (() -> Void)? {
        get { lock.withLock { activitySink } }
        set { lock.withLock { activitySink = newValue } }
    }

    private var accessUnitSink: ((Data, Bool) -> Void)?
    private var audioAccessUnitSink: ((Data) -> Void)?
    private var parameterSetsSink: ((CodecParameterSets) -> Void)?
    private var encoderResolutionSink: ((Int, Int) -> Void)?
    private var previewImageSink: ((Data) -> Void)?
    private var unexpectedExitSink: ((String) -> Void)?
    private var userStoppedSink: (() -> Void)?
    private var activitySink: (() -> Void)?

    // MARK: Errors

    /// The one start-error shape all three backends throw.
    /// `unsupportedSelection`/`captureUnavailable` carry the complete
    /// message, worded by each backend; the identical texts live in
    /// `description` here so they can't drift apart.
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
    /// **Software only, deliberately.** Distro hardware encoders
    /// (`h264_vaapi`/`h264_nvenc`/`h264_qsv`/`h264_amf`) consume *hardware*
    /// frames — needing an `AVHWFramesContext` upload the backends' software
    /// paths don't do — so listing one here would fail `avcodec_open2` on any
    /// machine without the matching device. Separate work, not a name in a list.
    public static let defaultH264Encoders = ["libx264", "libopenh264"]
    public static let defaultHEVCEncoders = ["libx265"]

    /// The names to try for a session, in order. HEVC is a preference, not a
    /// requirement: every viewer decodes H.264, and the Windows LGPL FFmpeg
    /// build has no software HEVC encoder at all, so an HEVC request falls
    /// through to the H.264 ladder rather than failing the share.
    public static func encoderLadder(wantHEVC: Bool) -> [String] {
        wantHEVC ? defaultHEVCEncoders + defaultH264Encoders : defaultH264Encoders
    }

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

    /// Anchor the starting bitrate the same way the mac helper does —
    /// `EncoderTuning`'s shared formula, clamped to any ceiling — so a share
    /// of the same pixels starts at the same budget on every platform.
    public static func anchoredBitrate(
        width: Int, height: Int, fps: Int, wantHEVC: Bool, ceiling: Int?
    ) -> Int {
        let codec: VideoCodec = wantHEVC ? .hevc : .h264
        let formulaBitrate = EncoderTuning.computeBitrate(
            width: width, height: height, fps: fps,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: codec))
        // `automaticCeilingBps`, not `formulaBitrate`, when no ceiling is set
        // — "automatic" bounds the formula rather than surrendering to it.
        return min(formulaBitrate, ceiling ?? QualitySettings.automaticCeilingBps)
    }

    /// The attempt ladder, generic over how an encoder opens so the ordering
    /// is testable without libavcodec having any encoder installed.
    /// Presence and usability differ — an encoder can be compiled in and
    /// still refuse to open — so the ladder is driven by `open` failing.
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

    /// Run the ladder against the real libavcodec. The opened encoder's
    /// `codec` may be H.264 even when `wantHEVC` is set (see
    /// ``encoderLadder(wantHEVC:)``); parameter sets and the RTP payload type
    /// follow `encoder.codec`, so nothing downstream reads `wantHEVC`.
    public static func openSoftwareEncoder(
        wantHEVC: Bool, width: Int, height: Int, fps: Int, bitrate: Int
    ) throws -> FFmpeg.VideoEncoder {
        let names = encoderLadder(wantHEVC: wantHEVC)
        let hevcNames = Set(defaultHEVCEncoders)
        let (opened, attempts) = firstOpenableEncoder(
            names: names,
            isAvailable: FFmpeg.isEncoderAvailable
        ) { name in
            try FFmpeg.VideoEncoder(
                codec: hevcNames.contains(name) ? .hevc : .h264, width: width, height: height,
                fps: fps, bitrate: bitrate, encoderName: name)
        }
        guard let opened else {
            throw StartError.encoderUnavailable(
                encoderUnavailableDetail(names: names, attempts: attempts))
        }
        return opened
    }

    // MARK: Failure budget

    /// The consecutive-capture-failure budget: a transient grab failure is
    /// worth retrying; a persistent one means the source is gone. The
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
        /// `subject` names the failing stage in the message.
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

    /// Guards every mutable field below, in this class and the subclass —
    /// one lock, so a backend's own state and the shared state read together consistently.
    public let lock = NSLock()
    public var encoder: FFmpeg.VideoEncoder?
    public var thread: Thread?
    public var running = false
    /// Target capture rate. Retuned live by `setFrameInterval` — the fps
    /// ladder's second congestion lever.
    public var targetFPS = 30
    public var sentParameterSets = false
    /// Set by `requestKeyframe` and consumed via `takeOwedKeyframe()` —
    /// needed where a keyframe may have to be produced with no new frame
    /// arriving. X11 forwards straight to the encoder instead and never reads this.
    public var keyframePending = false

    public init() {}

    deinit {
        // Synchronous teardown only — no Task capturing self after deinit has begun.
        lock.lock()
        running = false
        lock.unlock()
    }

    // MARK: Lifecycle

    /// Spawn the capture loop's thread and record it. The body should be
    /// `{ [weak self] in self?.captureLoop() }` — weak, so the thread doesn't
    /// keep a stopped backend alive.
    ///
    /// **Call it with `running` already true.** Check-and-record is one
    /// critical section: a `stop()` landing between them used to clear
    /// `thread` before this assigned it, or let `stop()` return having never
    /// seen the loop. A `stop()` that already won the race leaves the thread unstarted.
    public func startCaptureThread(named name: String, _ body: @escaping @Sendable () -> Void) {
        let captureThread = Thread { body() }
        captureThread.name = name
        let claimed = lock.withLock { () -> Bool in
            guard running else { return false }
            thread = captureThread
            return true
        }
        guard claimed else { return }
        captureThread.start()
    }

    /// How long `stop()` waits for the capture loop to observe the dropped
    /// flag before releasing resources. The loop holds no lock while it
    /// sleeps or waits on a frame, so one frame interval plus slack is
    /// enough; a backend whose wait is bounded differently overrides this.
    open var stopSettleMilliseconds: Int { 300 }

    /// Called by `stop()` right after the running flag drops and before the
    /// settle sleep. The portal backend releases its stream here — its
    /// deinit stops PipeWire's thread, guaranteeing no frame callback is in
    /// flight when buffers go away.
    open func willStopBeforeSettle() {}

    /// Called by `stop()` under `lock` after the settle sleep, for the
    /// subclass to nil out its own capture resources.
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

    /// Force an IDR on the next frame. Default latches `keyframePending` for
    /// backends that may re-encode a retained frame; X11 overrides to
    /// forward straight to the encoder.
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

    /// None of the three backends captures system audio. An explicit no-op
    /// so the server's re-send after a backend restart is harmless.
    public func setAudioEnabled(_ on: Bool) {}

    /// Retune the capture rate. Only pacing changes — RTP timestamps come
    /// from the server's own clock, not encoder PTS, so recreating the
    /// encoder would drop the stream for no benefit.
    public func setFrameInterval(_ fps: Int) {
        guard fps > 0 else { return }
        lock.withLock { targetFPS = fps }
    }

    // MARK: Parameter sets

    /// Pull SPS/PPS (or VPS/SPS/PPS) out of a keyframe access unit and hand
    /// them up once per encoder configuration. Parameter sets stay in-band on
    /// every keyframe regardless (lets a viewer join mid-stream); this
    /// callback exists because the server caches the codec from it, and the
    /// ordering contract (`onParameterSets` before `onEncoderResolution`)
    /// drives its bitrate anchor.
    ///
    /// NAL-type masks differ between codecs, and crossing them fails
    /// silently, so the table lives in `ParameterSetExtraction`, tested on Linux CI.
    public func emitParameterSets(from avcc: Data) {
        let (already, isHEVC, handler) = lock.withLock {
            (sentParameterSets, encoder?.codec == .hevc, parameterSetsSink)
        }
        guard !already, let handler else { return }
        guard let annexB = NALUnit.avccToAnnexB(avcc) else { return }
        guard
            let sets = ParameterSetExtraction.parameterSets(
                fromAnnexBNALs: NALUnit.annexBNALs(annexB),
                codec: isHEVC ? .hevc : .h264)
        else { return }
        // CLAIM the latch, don't merely set it — the read above is a cheap
        // early-out two threads can both pass, and emitting twice re-anchors
        // the server's bitrate controller on the second set. Parse stays
        // outside the lock; only the flip is atomic.
        let claimed = lock.withLock { () -> Bool in
            guard !sentParameterSets else { return false }
            sentParameterSets = true
            return true
        }
        guard claimed else { return }
        handler(sets)
    }
}
