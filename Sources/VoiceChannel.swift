import Foundation

/// Process-side voice pipeline: PCM in → AAC enc → RTP out, and RTP in →
/// AAC dec (per SSRC) → mixed PCM out. Hardware capture/playback glue is
/// in `MicCapture` (added in Task 7) which feeds this class.
///
/// Thread-safe via an internal serial queue: capture callbacks (audio
/// thread) and network callbacks (TailscaleKit reader task) call into
/// public methods which dispatch onto the queue. State only mutates on
/// the queue.
///
/// Marked `@unchecked Sendable`: all stored mutable state (`_isMuted`,
/// `decoders`, `brokenSSRCs`) is touched only from `queue`. `onMixedPCM`
/// is the documented exception — set it once before any `receive(_:)`.
final class VoiceChannel: @unchecked Sendable {
    let localSSRC: UInt32
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set { queue.sync { _isMuted = newValue } }
    }

    /// Invoked on the internal queue every time the encoder produces an
    /// RTP packet. Caller should pass it to the network layer.
    private let onSend: (Data) -> Void

    /// Invoked on the internal queue when the decoder produces a block of
    /// PCM samples for one inbound RTP audio packet. One call per packet
    /// per remote SSRC — mixing across peers is the caller's job (the
    /// audio engine in `MicCapture` schedules them into a shared player).
    ///
    /// Set this once before the first `receive(_:)` call. Mutating it
    /// concurrently with packet ingestion is unsafe; the queue reads it
    /// without synchronization.
    var onMixedPCM: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "VoiceChannel")
    private var _isMuted: Bool = true
    private let encoder: AACEncoder
    private let packetizer: AudioRTPPacketizer
    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: AACDecoder] = [:]
    private var brokenSSRCs: Set<UInt32> = []
    private var sentCount: Int = 0
    private var recvCount: Int = 0
    private var playedCount: Int = 0

    init(localSSRC: UInt32, onSend: @escaping (Data) -> Void) throws {
        self.localSSRC = localSSRC
        self.onSend = onSend
        self.encoder = try AACEncoder()
        self.packetizer = AudioRTPPacketizer(ssrc: localSSRC)
    }

    /// Push exactly 1024 PCM samples (one AAC AU's worth) for outbound
    /// transmission. No-op when muted.
    private var inboundFrameCount: Int = 0
    private var encodeNilCount: Int = 0
    func processOutboundFrame(_ pcm: [Float]) {
        queue.async {
            self.inboundFrameCount += 1
            if self.inboundFrameCount == 1 || self.inboundFrameCount == 2 || self.inboundFrameCount % 50 == 0 {
                print("VoiceChannel[ssrc=\(self.localSSRC)]: inbound frame #\(self.inboundFrameCount), muted=\(self._isMuted), pcm.count=\(pcm.count)")
            }
            guard !self._isMuted else { return }
            do {
                guard let au = try self.encoder.encode(pcm: pcm) else {
                    self.encodeNilCount += 1
                    if self.encodeNilCount == 1 || self.encodeNilCount == 2 || self.encodeNilCount % 50 == 0 {
                        print("VoiceChannel: encoder returned nil #\(self.encodeNilCount)")
                    }
                    return
                }
                let packet = self.packetizer.packetize(au: au)
                self.sentCount += 1
                if self.sentCount == 1 || self.sentCount % 50 == 0 {
                    print("VoiceChannel[ssrc=\(self.localSSRC)]: sent #\(self.sentCount) (\(packet.count) bytes)")
                }
                self.onSend(packet)
            } catch {
                print("VoiceChannel: encode failed: \(error)")
            }
        }
    }

    /// Ingest one inbound RTP audio packet. Decodes per SSRC and emits
    /// PCM via `onMixedPCM`.
    func receive(_ packet: Data) {
        queue.async {
            guard let parsed = self.depacketizer.unpack(packet) else { return }
            self.recvCount += 1
            if self.recvCount == 1 || self.recvCount % 50 == 0 {
                print("VoiceChannel[ssrc=\(self.localSSRC)]: recv #\(self.recvCount) from ssrc=\(parsed.ssrc) (\(parsed.au.count) bytes)")
            }
            // Drop our own loopback if the network somehow returned it.
            guard parsed.ssrc != self.localSSRC else { return }
            guard !self.brokenSSRCs.contains(parsed.ssrc) else { return }
            do {
                let decoder = try self.ensureDecoder(for: parsed.ssrc)
                let raw = try decoder.decode(au: parsed.au)
                if !raw.isEmpty {
                    // AudioToolbox AAC decoder occasionally emits
                    // out-of-range Float32 (peaks ~6.0 observed) on
                    // priming-adjacent frames or after a network
                    // glitch. Anything beyond [-1, 1] would clip the
                    // speakers into painful clicks, so clamp here.
                    let samples = raw.map { max(-1.0, min(1.0, $0)) }
                    self.playedCount += 1
                    if self.playedCount == 1 || self.playedCount % 50 == 0 {
                        print("VoiceChannel[ssrc=\(self.localSSRC)]: decoded #\(self.playedCount) from ssrc=\(parsed.ssrc) (\(samples.count) samples, mixedPCM=\(self.onMixedPCM != nil ? "wired" : "nil"))")
                    }
                    self.onMixedPCM?(samples)
                }
            } catch {
                if self.decoders[parsed.ssrc] == nil {
                    // Decoder init failed for this SSRC — blacklist so we
                    // don't spam stderr at 50 Hz.
                    self.brokenSSRCs.insert(parsed.ssrc)
                    print("VoiceChannel: decoder init failed for ssrc=\(parsed.ssrc): \(error). Dropping further packets from this SSRC.")
                } else {
                    // Decode (not init) failed — log once per packet but
                    // keep the decoder; transient corruption is normal.
                    print("VoiceChannel: decode failed for ssrc=\(parsed.ssrc): \(error)")
                }
            }
        }
    }

    /// Forget all per-SSRC decoders. Called when the share session ends
    /// so a future session starts fresh.
    func reset() {
        queue.async {
            self.decoders.removeAll()
            self.brokenSSRCs.removeAll()
        }
    }

    private func ensureDecoder(for ssrc: UInt32) throws -> AACDecoder {
        if let existing = decoders[ssrc] { return existing }
        let new = try AACDecoder()
        decoders[ssrc] = new
        return new
    }

#if DEBUG
    /// Drain the internal queue so test assertions can run synchronously
    /// after enqueuing outbound/inbound work.
    internal func flushForTesting() {
        queue.sync { }
    }
#endif
}

import AVFoundation
import CoreAudio

/// AVAudioEngine glue: input from VoiceProcessingIO mic (with built-in
/// AEC), output through the same VPIO unit (so AEC has the right
/// reference signal). Feeds inbound PCM frames into the VoiceChannel
/// and renders outbound PCM blocks the channel decoded from RTP.
/// Drains the AVAudioEngine input tap on the audio render thread and feeds
/// 1024-sample frames into the VoiceChannel. Lives outside `@MainActor`
/// because installTap fires on AVAudioEngine's serialized real-time queue;
/// hopping every callback to `@MainActor` (a) drops Swift 6 isolation
/// assertions, and (b) introduces unacceptable latency at 50 Hz.
///
/// All state is touched only from the tap callback, which AVAudioEngine
/// serializes — `@unchecked Sendable` is sound under that contract.
private final class TapBuffer: @unchecked Sendable {
    private let channel: VoiceChannel
    private var accumulator: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var sourceSampleRate: Double = 0
    private var lastSourceFormat: AVAudioFormat?

    var usesConverter: Bool { converter != nil }

    init?(channel: VoiceChannel) {
        self.channel = channel
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.targetFormat = target
    }

    /// Lazily (re)build the converter when the buffer's actual format
    /// differs from what we last saw. Required because
    /// `AVAudioInputNode.outputFormat(forBus:)` lies on macOS+VPIO until
    /// the first buffer renders — we install the tap with `format: nil`
    /// and discover the real format only when buffers start arriving.
    ///
    /// We always pre-extract channel 0 to mono before any sample-rate
    /// conversion. With VPIO, the input bus presents `[mic, ref_L,
    /// ref_R]`-style multi-channel layouts; AVAudioConverter's default
    /// 3ch→1ch downmix sums all channels (peak hits ~6.0 = clipped).
    /// Picking channel 0 explicitly gives clean mic audio.
    private func ensureConverter(for sourceFormat: AVAudioFormat) -> Bool {
        if let last = lastSourceFormat,
           last.sampleRate == sourceFormat.sampleRate,
           last.channelCount == sourceFormat.channelCount,
           last.commonFormat == sourceFormat.commonFormat {
            return true
        }
        lastSourceFormat = sourceFormat
        sourceSampleRate = sourceFormat.sampleRate

        // After mono extraction the pre-converter format is 1-channel
        // at the source's sample rate. If that already matches the
        // target (48 kHz mono Float32), no AVAudioConverter is needed.
        if sourceFormat.sampleRate == 48_000
            && sourceFormat.commonFormat == .pcmFormatFloat32 {
            converter = nil
            print("MicCapture: tap delivering \(sourceFormat) — using channel 0, no resample needed.")
            return true
        }
        guard let monoSource = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
              let conv = AVAudioConverter(from: monoSource, to: targetFormat)
        else {
            print("MicCapture: AVAudioConverter init failed for \(sourceFormat.sampleRate) → 48 kHz mono")
            converter = nil
            return false
        }
        converter = conv
        print("MicCapture: tap delivering \(sourceFormat) — picking channel 0, resampling \(sourceFormat.sampleRate) → 48 kHz.")
        return true
    }

    private var fireCount: Int = 0

    func process(_ buffer: AVAudioPCMBuffer) {
        fireCount += 1
        if fireCount == 1 || fireCount == 2 || fireCount == 5 || fireCount % 50 == 0 {
            print("MicCapture: tap fire #\(fireCount), \(buffer.frameLength) frames in \(buffer.format)")
        }
        guard ensureConverter(for: buffer.format) else { return }

        // Always extract just channel 0 (mic with VPIO; for raw input
        // it's the only channel that matters anyway). Build a fresh
        // mono PCMBuffer so AVAudioConverter sees a 1-channel stream
        // and never has to decide how to downmix.
        guard let srcCd = buffer.floatChannelData?[0] else { return }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return }

        // Fast path: input already 48 kHz Float32 — channel 0 is the
        // final mono audio, no conversion needed.
        if converter == nil {
            let samples = Array(UnsafeBufferPointer(start: srcCd, count: frameLen))
            appendAndDrain(samples)
            return
        }

        guard let converter = converter,
              let monoFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let monoBuf = AVAudioPCMBuffer(
                pcmFormat: monoFmt,
                frameCapacity: AVAudioFrameCount(frameLen)
              ),
              let monoCd = monoBuf.floatChannelData?[0]
        else { return }
        monoBuf.frameLength = AVAudioFrameCount(frameLen)
        memcpy(monoCd, srcCd, frameLen * MemoryLayout<Float>.size)

        // Output capacity: input frames scaled by sample-rate ratio + slack
        // for converter buffering.
        let ratio = 48_000.0 / sourceSampleRate
        let outCap = AVAudioFrameCount(Double(frameLen) * ratio + 64)
        guard outCap > 0,
              let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap)
        else { return }

        final class OneShot: @unchecked Sendable {
            var done = false
            var buffer: AVAudioPCMBuffer?
        }
        let flag = OneShot()
        flag.buffer = monoBuf
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { [flag] _, statusOut in
            if flag.done {
                // `.noDataNow`, NOT `.endOfStream`. AVAudioConverter
                // latches endOfStream and permanently refuses input
                // after seeing it once — making this a one-shot
                // converter when we want a streaming one.
                statusOut.pointee = .noDataNow
                return nil
            }
            flag.done = true
            statusOut.pointee = .haveData
            return flag.buffer
        }
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error {
            print("MicCapture: AVAudioConverter convert failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        guard let cd = outBuf.floatChannelData?[0] else { return }
        let frameCount = Int(outBuf.frameLength)
        if fireCount == 1 || fireCount == 2 || fireCount % 50 == 0 {
            print("MicCapture: convert fire #\(fireCount) status=\(status.rawValue) frames=\(frameCount)")
        }
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: cd, count: frameCount))
        appendAndDrain(samples)
    }

    private var drainCount: Int = 0
    private func appendAndDrain(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        while accumulator.count >= 1024 {
            let frame = Array(accumulator.prefix(1024))
            accumulator.removeFirst(1024)
            drainCount += 1
            if drainCount == 1 || drainCount == 2 || drainCount % 50 == 0 {
                print("MicCapture: drain #\(drainCount), accumulator=\(accumulator.count)")
            }
            channel.processOutboundFrame(frame)
        }
    }
}

@MainActor
final class MicCapture {
    private let channel: VoiceChannel
    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private let mixer: AVAudioMixerNode
    private let outputFormat: AVAudioFormat
    private var tapBuffer: TapBuffer?
    private var isPlaying = false
    private(set) var isCapturing = false
    private var configChangeObserver: NSObjectProtocol?

    /// Silent sink that pulls the input node continuously. AVAudioEngine
    /// only renders an input node when something downstream is pulling
    /// from it (the output device, ultimately) — installing a tap alone
    /// is *not* enough on macOS, the tap is a passive observer. Without
    /// this connection, the engine pulls input exactly once during
    /// start-up and then idles, which surfaces as "exactly one tap
    /// buffer, then silence". `outputVolume = 0` keeps the user from
    /// hearing their own voice through the speakers.
    private let inputSinkMixer = AVAudioMixerNode()
    private var inputSinkConnected = false

    /// When `TAILSCREEN_VOICE_TEST_TONE=1`, capture skips the mic
    /// entirely and feeds a generated 440 Hz sine into the encoder.
    /// Lets us isolate codec/transport/playback bugs from
    /// AEC/feedback issues when running two instances on one Mac.
    private var testToneTimer: DispatchSourceTimer?
    private static var isTestToneEnabled: Bool {
        ProcessInfo.processInfo.environment["TAILSCREEN_VOICE_TEST_TONE"] == "1"
    }

    init(channel: VoiceChannel) {
        self.channel = channel
        self.mixer = engine.mainMixerNode
        // 48 kHz mono Float32 — matches the codec format.
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("AVAudioFormat init failed for 48kHz mono Float32")
        }
        self.outputFormat = fmt

        // Pipe decoded PCM (per-SSRC mix already done by VoiceChannel)
        // into a player node so the user hears it.
        channel.onMixedPCM = { [weak self] samples in
            Task { @MainActor [weak self] in self?.scheduleSamples(samples) }
        }

        // AVAudioEngine reconfigures itself on route/format change (mic
        // hot-plug, sample-rate negotiation when VPIO engages, default-
        // device flip). Reconfigure tears down node connections, so an
        // installed input tap stops firing — observed as "exactly one
        // packet, then silence". Reinstall the tap whenever this fires.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reinstallTapAfterConfigChange() }
        }
    }

    /// Start the playback half of the engine. Builds the player → mixer →
    /// output graph and starts the engine without touching the input node,
    /// so listening works without prompting for microphone permission.
    func startPlayback() throws {
        guard !isPlaying else { return }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: outputFormat)
        playerNodes.append(player)
        try engine.start()
        // Don't call player.play() yet. scheduleSamples kicks
        // playback off only after `jitterBufferThreshold` buffers
        // are queued, so the player has runway and doesn't underrun
        // on the first arrival hiccup.
        isPlaying = true
        print("MicCapture: playback engine started (output-only, no mic, awaiting jitter buffer).")
    }

    /// Enable microphone capture. Requests permission, restarts the engine
    /// with VoiceProcessingIO enabled (for hardware AEC), and installs the
    /// input tap. Throws if permission is denied or the engine reconfigure
    /// fails.
    func enableCapture() async throws {
        guard !isCapturing else { return }

        // Test-tone bypass: skip the mic entirely, feed a 440 Hz
        // sine wave into VoiceChannel at the AAC frame cadence
        // (1024 samples / 48 kHz ≈ 21.33 ms). Useful for testing
        // codec + transport + playback in isolation without AEC
        // contention from running two instances on one Mac.
        if Self.isTestToneEnabled {
            startTestTone()
            isCapturing = true
            print("MicCapture: capture started in TEST-TONE mode (440 Hz sine, no mic).")
            return
        }

        let granted = await Self.requestMicPermission()
        guard granted else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }

        // setVoiceProcessingEnabled requires the engine to be stopped.
        if isPlaying { engine.stop() }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Don't swallow: without VPIO the input is whatever raw
            // hardware format AVAudioEngine picks (e.g. 5ch 44.1kHz from
            // an aggregate device), AEC is off, and the resulting tap
            // often fires once before the engine renegotiates.
            print("MicCapture: VPIO not engaged: \(error). Continuing without AEC.")
        }

        print("MicCapture: default input device = \(Self.defaultInputDeviceName() ?? "<unknown>")")

        guard let buffer = TapBuffer(channel: channel) else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate TapBuffer target format"]
            )
        }
        self.tapBuffer = buffer

        // Wire the input node into the active processing graph so the
        // engine pulls it every render cycle. See `inputSinkMixer`
        // doc-comment — the tap alone doesn't drive rendering on macOS.
        if !inputSinkConnected {
            engine.attach(inputSinkMixer)
            inputSinkMixer.outputVolume = 0
            engine.connect(engine.inputNode, to: inputSinkMixer, format: nil)
            engine.connect(inputSinkMixer, to: mixer, format: outputFormat)
            inputSinkConnected = true
        }

        // Install the tap BEFORE `engine.start()`, with `format: nil`.
        // `format: nil` lets AVAudioEngine deliver whatever format the
        // input actually produces; pre-start `outputFormat(forBus:)`
        // lies (returns the *output* device's stream description), so
        // we discover the real format lazily inside TapBuffer on the
        // first buffer.
        Self.installTap(on: engine.inputNode, buffer: buffer)

        try engine.start()
        for player in playerNodes { player.play() }
        print("MicCapture: capture started, engineRunning=\(engine.isRunning), inputSinkConnected=\(inputSinkConnected), inputSinkMixer.outputVolume=\(inputSinkMixer.outputVolume)")

        isCapturing = true
    }

    /// Disable microphone capture. Removes the tap; engine stays running
    /// for playback.
    func disableCapture() {
        guard isCapturing else { return }
        if let t = testToneTimer {
            t.cancel()
            testToneTimer = nil
            isCapturing = false
            print("MicCapture: test-tone capture disabled.")
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        tapBuffer = nil
        isCapturing = false
        print("MicCapture: capture disabled.")
    }

    func stop() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            tapBuffer = nil
            isCapturing = false
        }
        if isPlaying {
            for node in playerNodes { node.stop() }
            engine.stop()
            playerNodes.removeAll()
            isPlaying = false
        }
    }

    /// Called from the AVAudioEngineConfigurationChange notification.
    /// Reconfigure tears down node connections, including the input tap,
    /// so capture goes dead after one buffer. Re-derive the input format
    /// (it may have changed — e.g. VPIO renegotiated to mono 24 kHz),
    /// rebuild the converter, reinstall the tap, and restart the engine.
    private func reinstallTapAfterConfigChange() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        guard let buffer = TapBuffer(channel: channel) else {
            print("MicCapture: configuration change — TapBuffer alloc failed; capture stalled.")
            return
        }
        self.tapBuffer = buffer
        Self.installTap(on: engine.inputNode, buffer: buffer)
        if !engine.isRunning {
            do {
                try engine.start()
                for player in playerNodes { player.play() }
            } catch {
                print("MicCapture: configuration change — engine restart failed: \(error)")
                return
            }
        }
        print("MicCapture: tap reinstalled after configuration change.")
    }

    /// Mutable state for the test-tone timer. Lives outside
    /// `@MainActor` so the timer queue can mutate phase without
    /// hopping. `@unchecked Sendable` is sound because only the
    /// timer queue touches `phase`.
    private final class TestToneState: @unchecked Sendable {
        var phase: Float = 0
    }

    /// Generate a 440 Hz sine wave and push it into `channel` as
    /// 1024-sample frames at the AAC frame cadence. Each frame is
    /// `1024 / 48000` ≈ 21.33 ms; we run a serial DispatchSource
    /// timer at that interval. Phase accumulates across frames so
    /// the sine stays continuous (no clicks at frame boundaries).
    private func startTestTone() {
        // Build the timer in a nonisolated context. Otherwise the
        // closure passed to setEventHandler implicitly inherits
        // MicCapture's @MainActor isolation, and Swift 6's runtime
        // executor check trips `dispatch_assert_queue_fail` when the
        // timer queue dispatches a MainActor-isolated closure.
        testToneTimer = Self.makeTestToneTimer(channel: channel)
    }

    nonisolated private static func makeTestToneTimer(channel: VoiceChannel) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MicCapture.testTone"))
        let intervalNs = UInt64(1024.0 / 48_000.0 * 1_000_000_000)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)))
        let state = TestToneState()
        let handler: @Sendable () -> Void = {
            fillTestTone(state: state, channel: channel)
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    nonisolated private static func fillTestTone(state: TestToneState, channel: VoiceChannel) {
        let twoPi = Float(2.0 * .pi)
        let freq: Float = 440
        let sampleRate: Float = 48_000
        let frameSize = 1024
        let amplitude: Float = 0.3
        var samples = [Float](repeating: 0, count: frameSize)
        var phase = state.phase
        let increment = twoPi * freq / sampleRate
        for i in 0..<frameSize {
            samples[i] = amplitude * sinf(phase)
            phase += increment
            if phase >= twoPi { phase -= twoPi }
        }
        state.phase = phase
        channel.processOutboundFrame(samples)
    }

    /// Look up the human-readable name of the system default input device
    /// via CoreAudio. Used purely for diagnostic logging — when capture
    /// goes one-and-done, the name often reveals a virtual loopback
    /// (BlackHole, Loopback, an aggregate) sitting where the user assumes
    /// the built-in mic is.
    nonisolated private static func defaultInputDeviceName() -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(
            deviceID, &nameAddr, 0, nil, &nameSize, &name
        )
        guard nameStatus == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    /// Install the input tap from a nonisolated context so the closure
    /// AVAudioEngine retains does not inherit `@MainActor` isolation from
    /// `start()`. Without this, the audio render thread invoking the tap
    /// trips Swift 6's `dispatch_assert_queue` check (SIGTRAP) on the very
    /// first buffer.
    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        buffer: TapBuffer
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { avBuffer, _ in
            buffer.process(avBuffer)
        }
    }

    private var scheduledCount: Int = 0
    private var droppedCount: Int = 0

    /// Number of buffers to queue ahead before kicking playback off.
    /// Each buffer is 1024 samples ≈ 21.33 ms at 48 kHz, so 3 buffers
    /// = ~64 ms of headroom — enough to absorb startup jitter without
    /// an audible delay.
    private let jitterBufferThreshold = 3

    /// Hard cap on the player's pending-buffer queue. The sender's
    /// `DispatchSourceTimer` drifts a hair faster than the receiver's
    /// audio clock, so over time the queue grows unbounded → seconds
    /// of playback latency that you hear when muting (queue keeps
    /// draining after the sender stops). When the queue would exceed
    /// this cap, we drop the incoming buffer instead of scheduling
    /// it, which eats one frame (~21 ms) at most and keeps end-to-end
    /// latency bounded near `jitterBufferThreshold * 21 ms`.
    private let maxPendingBuffers = 6

    /// Pending-buffer counter. AVAudioPlayerNode doesn't expose its
    /// queue depth, so we increment on schedule and decrement in the
    /// completion handler. Touched only on @MainActor.
    private var pendingBuffers: Int = 0

    private func scheduleSamples(_ samples: [Float]) {
        guard isPlaying, let player = playerNodes.first else {
            print("MicCapture: scheduleSamples drop — isPlaying=\(isPlaying), players=\(playerNodes.count)")
            return
        }
        if pendingBuffers >= maxPendingBuffers {
            droppedCount += 1
            if droppedCount == 1 || droppedCount % 50 == 0 {
                print("MicCapture: dropping buffer #\(droppedCount) — queue at cap (\(pendingBuffers))")
            }
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        for (i, sample) in samples.enumerated() {
            dst[i] = sample
            let abs = sample < 0 ? -sample : sample
            if abs > peak { peak = abs }
        }
        scheduledCount += 1
        pendingBuffers += 1
        if scheduledCount == 1 || scheduledCount % 50 == 0 {
            print("MicCapture: scheduled #\(scheduledCount) (pending=\(pendingBuffers), peak=\(peak), playerPlaying=\(player.isPlaying), engineRunning=\(engine.isRunning))")
        }
        player.scheduleBuffer(buffer) { [weak self] in
            // Completion fires on AVAudioPlayer's render thread.
            // Hop to MainActor before mutating @MainActor state.
            Task { @MainActor [weak self] in
                self?.pendingBuffers -= 1
            }
        }
        // Defer the first play() until we have a small queue ahead.
        if !player.isPlaying && scheduledCount >= jitterBufferThreshold {
            player.play()
        }
    }

    private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
